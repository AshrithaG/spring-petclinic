/*
 * DevSecOps pipeline for spring-petclinic.
 *
 * Stages: Build & Test -> SonarQube static analysis -> (Quality Gate)
 *         -> Deploy to production VM with Ansible -> OWASP ZAP DAST scan
 *         -> publish ZAP HTML report.
 *
 * Prerequisites (see devsecops/README.md):
 *   - Jenkins/SonarQube/Prometheus/Grafana/ZAP running on devsecops-net
 *     (devsecops/docker-compose.yml)
 *   - Jenkins credential 'prod-vm-ssh' (SSH private key for the VM user)
 *   - SonarQube server named 'SonarQube' in Manage Jenkins -> System,
 *     with a token credential
 *   - PROD_HOST below and devsecops/ansible/inventory.ini set to the
 *     production VM's IP
 */
pipeline {
    agent any

    // Poll GitHub every ~2 minutes; a push triggers a build on the next poll.
    triggers {
        pollSCM('H/2 * * * *')
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
    }

    parameters {
        booleanParam(
            name: 'ZAP_FULL_SCAN',
            defaultValue: false,
            description: 'Also run a ZAP active scan (thorough but slow). ' +
                         'Default is spider + passive scan (baseline-style).'
        )
    }

    environment {
        // Production VM IP - must match devsecops/ansible/inventory.ini
        PROD_HOST = '192.168.252.2'
        APP_URL   = "http://${PROD_HOST}:8080"
        // ZAP daemon, reachable by container name on devsecops-net
        ZAP_URL   = 'http://zap:8090'
    }

    stages {

        stage('Build & Unit Tests') {
            steps {
                // MySqlIntegrationTests / PostgresIntegrationTests need a
                // Docker daemon (Testcontainers), which the Jenkins
                // container does not have - exclude them.
                sh """
                    ./mvnw -B clean package \
                        -Dtest='!MySqlIntegrationTests,!PostgresIntegrationTests' \
                        -Dsurefire.failIfNoSpecifiedTests=false
                """
            }
            post {
                always {
                    junit allowEmptyResults: true,
                          testResults: 'target/surefire-reports/*.xml'
                }
                success {
                    archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                // 'SonarQube' = server name configured in
                // Manage Jenkins -> System -> SonarQube servers
                withSonarQubeEnv('SonarQube') {
                    sh """
                        ./mvnw -B sonar:sonar \
                            -Dsonar.projectKey=spring-petclinic \
                            -Dsonar.projectName='Spring PetClinic'
                    """
                }
            }
        }

        stage('Quality Gate') {
            steps {
                // Requires the SonarQube webhook to http://jenkins:8080/sonarqube-webhook/
                // (README step 7). Marked UNSTABLE instead of failing the
                // whole pipeline if the gate times out or fails.
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    timeout(time: 5, unit: 'MINUTES') {
                        waitForQualityGate abortPipeline: false
                    }
                }
            }
        }

        stage('Deploy to Production VM (Ansible)') {
            steps {
                // Fixed jar name so the playbook has a stable path
                sh 'cp target/spring-petclinic-*.jar target/petclinic.jar'
                // 'prod-vm-ssh' = Jenkins SSH-key credential for the VM user
                sshagent(credentials: ['prod-vm-ssh']) {
                    sh """
                        cd devsecops/ansible
                        ansible-playbook deploy-petclinic.yml \
                            -e jar_file=${WORKSPACE}/target/petclinic.jar
                    """
                }
            }
        }

        stage('Smoke Test (welcome page)') {
            steps {
                sh """
                    curl -sf --retry 10 --retry-delay 5 --retry-all-errors ${APP_URL} \
                        | grep -qi 'PetClinic' && echo 'Welcome page is up.'
                """
            }
        }

        stage('Security Scan (OWASP ZAP)') {
            steps {
                sh '''
                    set -e
                    echo "Scanning ${APP_URL} via ZAP daemon at ${ZAP_URL}"

                    # Fresh session so the report only covers this build
                    curl -s "${ZAP_URL}/JSON/core/action/newSession/?name=build-${BUILD_NUMBER}&overwrite=true" > /dev/null

                    # 1) Spider the deployed application
                    scan_id=$(curl -s "${ZAP_URL}/JSON/spider/action/scan/?url=${APP_URL}&recurse=true" | jq -r '.scan')
                    while status=$(curl -s "${ZAP_URL}/JSON/spider/view/status/?scanId=${scan_id}" | jq -r '.status'); \
                          [ "${status}" != "100" ]; do
                        echo "  spider: ${status}%"; sleep 5
                    done

                    # 2) Let the passive scanner finish analysing all responses
                    while records=$(curl -s "${ZAP_URL}/JSON/pscan/view/recordsToScan/" | jq -r '.recordsToScan'); \
                          [ "${records}" != "0" ]; do
                        echo "  passive scan queue: ${records}"; sleep 5
                    done

                    # 3) Optional active scan (attacks the app; slow)
                    if [ "${ZAP_FULL_SCAN}" = "true" ]; then
                        ascan_id=$(curl -s "${ZAP_URL}/JSON/ascan/action/scan/?url=${APP_URL}&recurse=true" | jq -r '.scan')
                        while status=$(curl -s "${ZAP_URL}/JSON/ascan/view/status/?scanId=${ascan_id}" | jq -r '.status'); \
                              [ "${status}" != "100" ]; do
                            echo "  active scan: ${status}%"; sleep 15
                        done
                    fi

                    # 4) Pull the HTML report out of ZAP
                    mkdir -p zap-reports
                    curl -s "${ZAP_URL}/OTHER/core/other/htmlreport/" -o zap-reports/zap-report.html
                    alerts=$(curl -s "${ZAP_URL}/JSON/core/view/numberOfAlerts/" | jq -r '.numberOfAlerts')
                    echo "ZAP finished: ${alerts} alert(s). Report: zap-reports/zap-report.html"
                '''
            }
            post {
                always {
                    // Post-build action: publish the ZAP report
                    publishHTML(target: [
                        reportName:            'ZAP Security Report',
                        reportDir:             'zap-reports',
                        reportFiles:           'zap-report.html',
                        keepAll:               true,
                        alwaysLinkToLastBuild: true,
                        allowMissing:          false
                    ])
                    archiveArtifacts artifacts: 'zap-reports/*', allowEmptyArchive: true
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline OK - app deployed at ${APP_URL}"
        }
        failure {
            echo 'Pipeline failed - check the stage logs (Blue Ocean gives the clearest view).'
        }
    }
}

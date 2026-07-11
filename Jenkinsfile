pipeline {
    agent any

    // check GitHub for new commits every couple of minutes
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
            description: 'Run a full ZAP active scan on top of the baseline passive scan. Slow.'
        )
    }

    environment {
        // production VM address and user, can be overridden per instance
        // by setting PROD_HOST_OVERRIDE / PROD_USER_OVERRIDE on the container
        PROD_HOST = "${env.PROD_HOST_OVERRIDE ?: '192.168.252.2'}"
        PROD_USER = "${env.PROD_USER_OVERRIDE ?: 'ubuntu'}"
        APP_URL   = "http://${PROD_HOST}:8080"
        ZAP_URL   = 'http://zap:8090'
    }

    stages {

        stage('Build & Unit Tests') {
            steps {
                // the ZAP report from the previous run contains http:// URLs
                // that the nohttp checkstyle rule rejects, so clear it first
                sh 'rm -rf zap-reports'
                // the MySql and Postgres integration tests need a Docker
                // daemon (Testcontainers), which this container does not have
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
                // non blocking by choice: a failed gate marks the build
                // UNSTABLE instead of stopping delivery, see the README
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    timeout(time: 5, unit: 'MINUTES') {
                        waitForQualityGate abortPipeline: false
                    }
                }
            }
        }

        stage('Deploy to Production VM (Ansible)') {
            steps {
                sh 'cp target/spring-petclinic-*.jar target/petclinic.jar'
                sshagent(credentials: ['prod-vm-ssh']) {
                    sh """
                        cd devsecops/ansible
                        ansible-playbook -i '${PROD_HOST},' -e ansible_user=${PROD_USER} \
                            -e jar_file=${WORKSPACE}/target/petclinic.jar \
                            deploy-petclinic.yml
                    """
                }
            }
        }

        stage('Smoke Test') {
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
                    echo "Scanning ${APP_URL} via ZAP at ${ZAP_URL}"

                    curl -s "${ZAP_URL}/JSON/core/action/newSession/?name=build-${BUILD_NUMBER}&overwrite=true" > /dev/null

                    scan_id=$(curl -s "${ZAP_URL}/JSON/spider/action/scan/?url=${APP_URL}&recurse=true" | jq -r '.scan')
                    while status=$(curl -s "${ZAP_URL}/JSON/spider/view/status/?scanId=${scan_id}" | jq -r '.status'); \
                          [ "${status}" != "100" ]; do
                        echo "  spider: ${status}%"; sleep 5
                    done

                    while records=$(curl -s "${ZAP_URL}/JSON/pscan/view/recordsToScan/" | jq -r '.recordsToScan'); \
                          [ "${records}" != "0" ]; do
                        echo "  passive scan queue: ${records}"; sleep 5
                    done

                    if [ "${ZAP_FULL_SCAN}" = "true" ]; then
                        ascan_id=$(curl -s "${ZAP_URL}/JSON/ascan/action/scan/?url=${APP_URL}&recurse=true" | jq -r '.scan')
                        while status=$(curl -s "${ZAP_URL}/JSON/ascan/view/status/?scanId=${ascan_id}" | jq -r '.status'); \
                              [ "${status}" != "100" ]; do
                            echo "  active scan: ${status}%"; sleep 15
                        done
                    fi

                    mkdir -p zap-reports
                    curl -s "${ZAP_URL}/OTHER/core/other/htmlreport/" -o zap-reports/zap-report.html
                    alerts=$(curl -s "${ZAP_URL}/JSON/core/view/numberOfAlerts/" | jq -r '.numberOfAlerts')
                    echo "ZAP finished with ${alerts} alerts"
                '''
            }
            post {
                always {
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
            echo "Pipeline OK, app deployed at ${APP_URL}"
        }
        failure {
            echo 'Pipeline failed, check the stage logs.'
        }
    }
}

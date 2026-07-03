pipeline {
    agent any

    triggers {
        pollSCM('H/5 * * * *')
    }

    environment {
        SONAR_TOKEN = credentials('sonar-token')
        APP_URL     = 'http://prod-server:8080'
        ZAP_URL     = 'http://zap:8090'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build & Test') {
            steps {
                sh './mvnw clean verify -Dmaven.test.failure.ignore=false'
            }
            post {
                always {
                    junit 'target/surefire-reports/*.xml'
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh '''
                        ./mvnw sonar:sonar \
                            -Dsonar.projectKey=spring-petclinic \
                            -Dsonar.projectName="Spring PetClinic" \
                            -Dsonar.token=${SONAR_TOKEN}
                    '''
                }
            }
        }

        stage('Quality Gate') {
            steps {
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Deploy to Production') {
            steps {
                ansiblePlaybook(
                    playbook: 'devsecops/ansible/playbook.yml',
                    inventory: 'devsecops/ansible/inventory',
                    disableHostKeyChecking: true,
                    extras: "-e workspace=${WORKSPACE} -e ansible_ssh_pass=deploy123 -e ansible_become_pass=deploy123"
                )
            }
        }

        stage('ZAP Security Scan') {
            steps {
                script {
                    sh "curl -s '${ZAP_URL}/JSON/core/action/newSession/?name=petclinic&overwrite=true'"

                    sh "curl -s '${ZAP_URL}/JSON/spider/action/scan/?url=${APP_URL}&recurse=true&maxChildren=10'"

                    timeout(time: 5, unit: 'MINUTES') {
                        waitUntil {
                            def pct = sh(
                                script: "curl -s '${ZAP_URL}/JSON/spider/view/status/' | python3 -c \"import sys,json; print(json.load(sys.stdin)['status'])\"",
                                returnStdout: true
                            ).trim()
                            return pct == '100'
                        }
                    }

                    sh "curl -s '${ZAP_URL}/JSON/ascan/action/scan/?url=${APP_URL}&recurse=true'"

                    timeout(time: 15, unit: 'MINUTES') {
                        waitUntil {
                            def pct = sh(
                                script: "curl -s '${ZAP_URL}/JSON/ascan/view/status/' | python3 -c \"import sys,json; print(json.load(sys.stdin)['status'])\"",
                                returnStdout: true
                            ).trim()
                            return pct == '100'
                        }
                    }

                    sh "curl -s '${ZAP_URL}/OTHER/core/other/htmlreport/' > zap-report.html"
                    sh "curl -s '${ZAP_URL}/OTHER/core/other/xmlreport/' > zap-report.xml"
                }
            }
            post {
                always {
                    publishHTML(target: [
                        allowMissing: true,
                        alwaysLinkToLastBuild: true,
                        keepAll: true,
                        reportDir: '.',
                        reportFiles: 'zap-report.html',
                        reportName: 'ZAP Security Report'
                    ])
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
        }
        success {
            echo "Pipeline completed. App is live at ${APP_URL}"
        }
        failure {
            echo "Pipeline failed. Check the logs above."
        }
    }
}

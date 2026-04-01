pipeline {
    agent any

    environment {
        DOCKER_IMAGE = "hapi-fhir-server:${BUILD_NUMBER}"
        GITHUB_REPO  = "https://github.com/Ayataaki/Devops-hapi-fhir-jpaserver.git"
    }

    stages {

//        stage('Checkout') {
//            steps {
//                git branch: 'main', url: "${GITHUB_REPO}"
//            }
//        }

        stage('Build Maven') {
            steps {
                sh 'mvn clean package -DskipTests'
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh '''
                    mvn sonar:sonar \
                      -Dsonar.projectKey=hapi-fhir-observability \
                      -Dsonar.host.url=http://sonarqube-hapi-fhir:9000
                    '''
                }
            }
        }

        stage('Quality Gate') {
            steps {
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: false
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                sh 'docker build --target default -t $DOCKER_IMAGE .'
            }
        }

        stage('Deploy Stack') {
            steps {
                sh '''
                docker compose down
                docker compose up -d
                '''
            }
        }

        stage('Health Check') {
            steps {
                sh '''
                timeout 120 bash -c \
                'until curl -sf http://localhost:9099/fhir/metadata; do sleep 5; done'
                '''
            }
        }
    }
}
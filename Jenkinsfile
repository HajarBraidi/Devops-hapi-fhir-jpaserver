pipeline {
    agent any

    environment {
        DOCKER_IMAGE = "hapi-fhir-server:${BUILD_NUMBER}"
        SONAR_URL    = "http://sonarqube-hapi-fhir:9000"
    }

    tools {
        maven 'Maven'
    }

    stages {

        stage('Build Maven') {
            steps {
                echo 'Compilation du projet HAPI FHIR...'
                sh 'mvn clean package -DskipTests -Djdk.lang.Process.launchMechanism=vfork'
            }
        }

        stage('SonarQube Analysis') {
            steps {
                echo 'Analyse SonarQube...'
                withSonarQubeEnv('SonarQube') {
                    sh """
                        mvn sonar:sonar \
                          -Dsonar.projectKey=hapi-fhir-observability \
                          -Dsonar.projectName="HAPI FHIR Observability" \
                          -Dsonar.host.url=${SONAR_URL} \
                          -Dsonar.scm.disabled=true
                    """
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
                echo "Construction de l'image Docker ${DOCKER_IMAGE}..."
                sh 'docker build --target default -t ${DOCKER_IMAGE} -f Dockerfile .'
            }
        }

        stage('Deploy Stack') {
            steps {
                sh '''
                    docker compose down --remove-orphans || true
                    docker compose up -d
                '''
            }
        }

        stage('Health Check') {
            steps {
                sh '''
                    for i in $(seq 1 36); do
                        if curl -sf http://hapi-fhir-jpaserver-start:8080/fhir/metadata > /dev/null 2>&1; then
                            echo "HAPI FHIR est UP apres $((i*5)) secondes"
                            exit 0
                        fi
                        echo "Tentative $i/36 en attente 5s..."
                        sleep 5
                    done
                    echo "HAPI FHIR ne repond pas apres 3 minutes"
                    exit 1
                '''
            }
        }
    }

    post {
        success { echo 'Pipeline termine avec succes' }
        failure {
            sh 'docker stop hapi-fhir-jpaserver-start 2>/dev/null || true'
            echo 'Pipeline echoue'
        }
        always { echo "Build #${BUILD_NUMBER} termine" }
    }
}
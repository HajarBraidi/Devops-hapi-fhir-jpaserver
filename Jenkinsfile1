pipeline {
    agent any

    environment {
        DOCKER_IMAGE      = "hapi-fhir-server:latest"
        DOCKERFILE_PATH   = "./Dockerfile"
        GITHUB_REPO       = "https://github.com/Ayataaki/Devops-hapi-fhir-jpaserver.git"
        SONAR_PROJECT_KEY = "hapi-fhir-observability"
        // Nom du conteneur SonarQube dans le réseau Docker interne
        SONAR_HOST_URL    = "http://sonarqube-hapi-fhir:9000"
    }

    stages {

        // ── 1. Checkout ──────────────────────────────────────────
        stage('Checkout') {
            steps {
                echo 'Checkout du code depuis GitHub...'
                // Repo public : pas besoin de credentials
                git branch: 'main', url: "${GITHUB_REPO}"
            }
        }

        // ── 2. Build Docker Image ─────────────────────────────────
        stage('Build Docker Image') {
            steps {
                echo "Construction de l'image Docker HAPI FHIR..."
                sh """
                    docker build \
                        --target default \
                        -t ${DOCKER_IMAGE} \
                        -f ${DOCKERFILE_PATH} \
                        .
                """
            }
        }

        // ── 3. SonarQube Analysis ─────────────────────────────────
        // Analyse le CODE SOURCE Java dans le workspace Jenkins
        // PAS dans l'image Docker — c'est une erreur fréquente
        stage('SonarQube Analysis') {
            steps {
                echo 'Analyse SonarQube du code source Java...'
                withSonarQubeEnv('SonarQube') {
                    sh """
                        sonar-scanner \
                          -Dsonar.projectKey=${SONAR_PROJECT_KEY} \
                          -Dsonar.projectName="HAPI FHIR Observability" \
                          -Dsonar.projectVersion=1.0 \
                          -Dsonar.sources=src/main/java \
                          -Dsonar.java.binaries=target/classes \
                          -Dsonar.exclusions=**/target/**,**/*.xml,**/test/** \
                          -Dsonar.host.url=${SONAR_HOST_URL} \
                          -Dsonar.scm.disabled=true
                    """
                }
            }
        }

        // ── 4. Quality Gate ───────────────────────────────────────
        stage('Quality Gate') {
            steps {
                echo 'Vérification du Quality Gate SonarQube...'
                timeout(time: 5, unit: 'MINUTES') {
                    // abortPipeline: false = on continue même si le gate échoue
                    // Mettre true en production pour bloquer le déploiement
                    waitForQualityGate abortPipeline: false
                }
            }
        }

        // ── 5. Deploy Stack ───────────────────────────────────────
        stage('Deploy Stack') {
            steps {
                echo 'Démarrage de la stack observabilité...'
                sh 'docker compose up -d'
            }
        }

        // ── 6. Health Check ───────────────────────────────────────
        stage('Health Check') {
            steps {
                echo 'Attente que HAPI FHIR soit opérationnel...'
                sh """
                    echo 'Attente max 2 minutes...'
                    timeout 120 bash -c \
                        'until curl -sf http://hapi-fhir-jpaserver-start:8080/fhir/metadata > /dev/null; \
                         do echo "En attente..."; sleep 5; done'
                    echo "HAPI FHIR est UP et répond"
                """
            }
        }
    }

    post {
        success {
            echo '✅ Pipeline terminé avec succès'
        }
        failure {
            echo '❌ Pipeline échoué — vérifier les logs ci-dessus'
        }
        always {
            echo "Build #${BUILD_NUMBER} terminé"
        }
    }
}
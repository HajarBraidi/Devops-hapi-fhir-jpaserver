pipeline {
    agent {
        docker {
            image 'maven:3.9.5-eclipse-temurin-17'
            args '-v $HOME/.m2:/root/.m2'
        }
    }

    environment {
        SONAR_HOST_URL   = "http://sonarqube:9000"
        SONAR_AUTH_TOKEN = credentials('sonar-token')  // Token SonarQube
        GITHUB_REPO      = "https://github.com/Ayataaki/Devops-hapi-fhir-jpaserver.git"
        GITHUB_CREDENTIALS = "github-token"
    }

    parameters {
        booleanParam(name: 'RUN_SONAR', defaultValue: true, description: 'Activer SonarQube')
    }

    stages {

        stage('Checkout') {
            steps {
                echo 'Checkout du code...'
                git branch: 'main',
                    url: "${GITHUB_REPO}",
                    credentialsId: "${GITHUB_CREDENTIALS}"
            }
        }

        stage('SonarQube Analysis') {
            when { expression { return params.RUN_SONAR } }
            steps {
                echo 'Analyse SonarQube...'
                withSonarQubeEnv('SonarQube') {
                    sh 'mvn clean verify sonar:sonar -Dsonar.host.url=${SONAR_HOST_URL} -Dsonar.login=${SONAR_AUTH_TOKEN}'
                }
            }
        }

        stage('Quality Gate') {
            when { expression { return params.RUN_SONAR } }
            steps {
                echo 'Vérification du Quality Gate...'
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Archive') {
            steps {
                echo 'Archivage des artefacts...'
                archiveArtifacts(artifacts: 'results.csv,results_analysis.json,charts/**/*', allowEmptyArchive: true, fingerprint: true)
            }
        }
    }

    post {
        success {
            echo '✅ Pipeline terminé avec succès'
        }
        failure {
            echo '❌ Pipeline échoué'
        }
        always {
            echo "Build #${BUILD_NUMBER} terminé"
        }
    }
}
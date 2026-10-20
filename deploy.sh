./build.sh
aws ecs update-service --cluster bia-cluster --service service-bia  --force-new-deployment

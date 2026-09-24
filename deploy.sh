./build.sh
aws ecs update-service --cluster cluster-bia-v2 --service service-bia  --force-new-deployment

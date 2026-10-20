aws ssm start-session \
    --target i-0735ff921f0586b0a \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters '{"host":["bia.cpwwyg4syqmd.us-east-2.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5434"]}' \
    --region us-east-2
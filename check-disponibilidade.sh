url="http://bia-alb-16405425.us-east-2.elb.amazonaws.com/"
docker build -t check_disponibilidade -f Dockerfile_checkdisponibilidade .
docker run --rm -ti -e URL=$url check_disponibilidade

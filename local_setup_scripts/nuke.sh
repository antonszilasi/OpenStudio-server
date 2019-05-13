#!/bin/bash -e
echo "full redploy with OS version: $1"

docker stack rm osserver || true
docker service rm $(docker service ls -q) || true
docker swarm leave -f || true
echo "docker rm ps"
docker rm -f $(docker ps -aq) || true
echo "docker volume rm"
docker volume rm $(docker volume ls -q) || true
echo "docker image rm"
docker image rm -f $(docker image ls -aq) || true

echo "pull images"
docker pull registry:2.6
docker pull nrel/openstudio-server:$1
docker pull nrel/openstudio-rserve:$1
docker pull mongo:3.4.10
docker pull redis:4.0.6
docker pull nrel/openstudio-jupyter:latest
docker pull nrel/openstudio-rnotebook

echo "create registry"
docker volume create --name=regdata
docker swarm init
docker service create --name registry --publish 5000:5000 --mount type=volume,source=regdata,destination=/var/lib/registry registry:2.6
sleep 10
echo "tag"
docker tag nrel/openstudio-server:$1 127.0.0.1:5000/openstudio-server
docker tag nrel/openstudio-rserve:$1 127.0.0.1:5000/openstudio-rserve
docker tag mongo:3.4.10 127.0.0.1:5000/mongo
docker tag redis:4.0.6 127.0.0.1:5000/redis
docker tag nrel/openstudio-jupyter 127.0.0.1:5000/openstudio-jupyter
docker tag nrel/openstudio-rnotebook 127.0.0.1:5000/openstudio-rnotebook
sleep 3
echo "cleanup"
docker image rm mongo:3.4.10 -f
docker image rm redis:4.0.6 -f
docker image rm nrel/openstudio-server:$1 -f
docker image rm nrel/openstudio-rserve:$1 -f
docker image rm nrel/openstudio-jupyter:latest -f
docker image rm nrel/openstudio-rnotebook:latest -f
echo "push"
docker push 127.0.0.1:5000/openstudio-server
docker push 127.0.0.1:5000/openstudio-rserve
docker push 127.0.0.1:5000/mongo
docker push 127.0.0.1:5000/redis
docker push 127.0.0.1:5000/openstudio-jupyter
docker push 127.0.0.1:5000/openstudio-rnotebook

echo "deploy"
docker stack deploy osserver --compose-file=/home/ubuntu/Projects/OpenStudio-Server/local_setup_scripts/docker-compose.yml &
wait $!
while ( nc -zv 127.0.0.1 80 3>&1 1>&2- 2>&3- ) | awk -F ":" '$3 != " Connection refused" {exit 1}'; do sleep 5; done
docker service scale osserver_worker=42
echo 'osserver stack redeployed'

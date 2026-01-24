IMAGE:=ynkr-sh
TAG:=latest

docker: Dockerfile ynkr.sh ./lib/
	docker build -t $(IMAGE):$(TAG) .

cluster = m5-cluster
working_dir = $(shell pwd)
home_dir = $(HOME)
cmd = ansible-playbook -i /work/inventory/$(cluster).ini --become
# renovate: datasource=github-releases depName="kubernetes/kubernetes"
k8s_version = v1.30.4
# renovate: datasource=github-releases depName="kubernetes-sigs/kubespray"
kubespray_version = v2.27.0

create-cluster:
	docker run --user $(id -u):$(id -g) --network host --rm -it --mount type=bind,source="$(working_dir)",dst=/work \
    --mount type=bind,source="${HOME}"/.ssh,dst=/root/.ssh \
    quay.io/kubespray/kubespray:$(kubespray_version) $(cmd) cluster.yml -e kube_version=$(k8s_version)


upgrade-cluster:
	docker run --user $(id -u):$(id -g) --network host --rm -it --mount type=bind,source="$(working_dir)",dst=/work \
    --mount type=bind,source="${HOME}"/.ssh,dst=/root/.ssh \
    quay.io/kubespray/kubespray:$(kubespray_version) $(cmd) cluster.yml -e upgrade_cluster_setup=true -e kube_version=$(k8s_version)

reset-cluster:
	docker run --user $(id -u):$(id -g) --network host --rm -it --mount type=bind,source="$(working_dir)",dst=/work \
    --mount type=bind,source="${HOME}"/.ssh,dst=/root/.ssh \
    quay.io/kubespray/kubespray:$(kubespray_version) $(cmd) reset.yml

# Deploy a PyPI registry

This deployment uses the `pypiserver` docker image published [here](https://github.com/pypiserver/pypiserver#using-the-docker-image).

TODO's:
- [ ] No authentication so anyone can submit packages
- [ ] probably should use variables to accept a few parameters

## Setup your own PyPI

- Create an EFS drive for storing packages and update this id in `main.tf`

Follow the typical terraform steps for deployment

```sh
terraform init
terraform apply --auto-approve
```

to remove the instance

```sh
terraform destroy --auto-approve
```

## To publish packages

Build the distributions using your tool of choice. If you are using **_tox_**, 

this is as simple as `tox -e build`

Publish package to Registry

```sh
twine upload --repository-url <URL_WHERE_THIS_IS_RUNNING> dist/* --verbose
```

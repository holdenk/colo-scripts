#!/bin/bash
# Requires ansible >= 2.9
set -ex
ansible-galaxy collection install -r requirements.yaml
ansible-playbook -vvv -i hosts.yaml --vault-id dev@secret --extra-vars '@passwd.yml' ./playbooks/router.yaml 

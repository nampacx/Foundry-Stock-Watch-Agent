Intentionally (almost) empty. This is the `foundry` layer of `azure.yaml` (`provider: microsoft.foundry`):
the Foundry account, project and model deployment are synthesized by azd from the `ai-project` service,
so there are no template files here. `azd ai agent init --infra` would eject them into this folder.

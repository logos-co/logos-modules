update-blockchain: update-blockchain-module update-blockchain-ui

update-blockchain-module:
  git submodule update --remote logos-blockchain-module/

update-blockchain-ui:
  git submodule update --remote logos-blockchain-ui/


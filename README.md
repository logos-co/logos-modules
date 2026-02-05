# logos-modules

Run this to fetch all modules after cloning:

```sh
git submodule update --init --recursive
```

to compile all modules in one go
```sh
./compile.sh
```

## Modules

| Path | Repository |
| --- | --- |
| logos-blockchain-module | https://github.com/logos-blockchain/logos-blockchain-module |
| logos-waku-module | https://github.com/logos-co/logos-waku-module |
| logos-wallet-module | https://github.com/logos-co/logos-wallet-module |
| logos-chat-module | https://github.com/logos-co/logos-chat-module |
| logos-irc-module | https://github.com/logos-co/logos-irc-module |
| logos-package-manager | https://github.com/logos-co/logos-package-manager |
| logos-capability-module | https://github.com/logos-co/logos-capability-module |
| logos-accounts-module | https://github.com/logos-co/logos-accounts-module |
| logos-wallet-ui | https://github.com/logos-co/logos-wallet-ui |
| logos-chat-ui | https://github.com/logos-co/logos-chat-ui |
| logos-accounts-ui | https://github.com/logos-co/logos-accounts-ui |

## Requirements

- Modules must support compiling with `nix build '.#lib'`
- Modules output must go into `result/lib/*`
- Modules must have a `metadata.json`. If there are multiple files then the `main` field must be defined.

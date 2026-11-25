# Embedded libraries

Third-party libraries LFG+ carries so players install nothing else. They are **not** covered by the addon's
license; each keeps its own terms. LibStub loads only the newest copy when several addons embed the same library.

| Library | Version | Source | License |
|---|---|---|---|
| LibStub | minor 2 | https://repos.wowace.com/wow/libstub/trunk (r109) | Public domain |
| CallbackHandler-1.0 | minor 8 | https://repos.wowace.com/wow/callbackhandler/trunk | BSD-2 (per its TOC) |
| LibDataBroker-1.1 | minor 4 | https://github.com/tekkub/libdatabroker-1-1 | None stated; distributed for embedding |
| LibDBIcon-1.0 | minor 57 | https://repos.wowace.com/wow/libdbicon-1-0/trunk (r168) | All Rights Reserved; distributed for embedding |

Fetched 2026-11-08, unmodified. Only the `.lua` files are kept; `LFGPlus.toc` loads them directly, before the addon's
own files. To update one, replace its file with the newer upstream copy and run `./busted.sh`.

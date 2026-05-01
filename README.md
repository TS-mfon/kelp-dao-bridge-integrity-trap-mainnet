# Kelp DAO Bridge Integrity Trap

Drosera trap for Kelp DAO rsETH bridge integrity on Ethereum mainnet.

The trap is designed for the class of cross-chain bridge failure where a forged or invalid cross-chain message causes rsETH to be released from the Ethereum bridge escrow without a valid corresponding lock/burn on the source side. It monitors the Ethereum-side state that changes during that incident: the rsETH balance held by the LayerZero OFT adapter.

## Network

- Chain: Ethereum mainnet
- Drosera relay: `https://relay.ethereum.drosera.io`
- Default RPC: `https://ethereum-rpc.publicnode.com`

## Monitored Contracts

| Contract | Address | Role |
| --- | --- | --- |
| rsETH | `0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7` | Kelp DAO liquid restaking token |
| rsETH OFT Adapter | `0x85d456B2DfF1fd8245387C0BfB64Dfb700e98Ef3` | Ethereum bridge escrow / LayerZero adapter |

## Threat Model

The trap is focused on Ethereum-side symptoms of a bridge exploit:

- large rsETH escrow outflow from the OFT adapter
- severe adapter reserve ratio drop
- adapter or token codehash drift
- failed state collection
- invalid Drosera sample ordering

This does not prove whether the remote-chain message was valid. It gives Kelp DAO an immediate Ethereum-side signal that bridge escrow is being depleted faster than expected.

## Invariant

For consecutive valid samples:

```text
previousEscrowBalance - currentEscrowBalance <= allowedOutflow
```

The trap triggers when the outflow is both:

- at least `1,000 rsETH`
- at least `5%` of the previous adapter escrow balance

It escalates to critical if the outflow is at least `25,000 rsETH`.

## Response Function

```solidity
function handleKelpBridgeRisk(
    uint8 severity,
    uint256 reasonBitmap,
    address primaryTarget,
    uint256 blockNumber,
    bytes calldata context
) external;
```

The included `KelpDaoBridgeRiskResponse` is alert-only by default. It emits `KelpBridgeRiskHandled`. A production deployment can connect this to a privileged bridge pause executor only if Kelp DAO grants the response contract the required role.

## Reason Bitmap

| Bit | Reason |
| --- | --- |
| `1 << 0` | Bridge escrow outflow |
| `1 << 1` | Critical bridge escrow outflow |
| `1 << 2` | Escrow ratio drop |
| `1 << 3` | Escrow under minimum |
| `1 << 4` | Adapter codehash drift |
| `1 << 5` | Token codehash drift |
| `1 << 6` | Collect failed |
| `1 << 7` | Invalid sample window |

## Build and Test

```bash
forge build
forge test -vvv
drosera dryrun
```

## Deployment Notes

Before deployment, replace the placeholder `response_contract` in `drosera.toml` with the deployed `KelpDaoBridgeRiskResponse` or Kelp-approved incident router.

The trap was generated using the local Drosera MCP context and follows the Drosera `collect()` / `shouldRespond()` interface used in the provided Drosera examples.


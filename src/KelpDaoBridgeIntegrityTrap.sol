// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "./ITrap.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract KelpDaoBridgeIntegrityTrap is ITrap {
    address public constant RSETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address public constant RSETH_OFT_ADAPTER = 0x85d456B2DfF1fd8245387C0BfB64Dfb700e98Ef3;

    uint256 public constant REQUIRED_SAMPLES = 2;
    uint256 public constant MAX_BLOCK_GAP = 32;
    uint256 public constant BPS = 10_000;
    uint256 public constant LARGE_OUTFLOW_BPS = 500;
    uint256 public constant LARGE_OUTFLOW_ABSOLUTE = 1_000 ether;
    uint256 public constant CRITICAL_OUTFLOW_ABSOLUTE = 25_000 ether;
    uint256 public constant MIN_ESCROW_RATIO_BPS = 500;

    uint8 public constant SEVERITY_NONE = 0;
    uint8 public constant SEVERITY_WARNING = 1;
    uint8 public constant SEVERITY_HIGH = 2;
    uint8 public constant SEVERITY_CRITICAL = 3;

    uint256 public constant REASON_BRIDGE_ESCROW_OUTFLOW = 1 << 0;
    uint256 public constant REASON_CRITICAL_ESCROW_OUTFLOW = 1 << 1;
    uint256 public constant REASON_ESCROW_RATIO_DROP = 1 << 2;
    uint256 public constant REASON_ESCROW_UNDER_MINIMUM = 1 << 3;
    uint256 public constant REASON_ADAPTER_CODEHASH_DRIFT = 1 << 4;
    uint256 public constant REASON_TOKEN_CODEHASH_DRIFT = 1 << 5;
    uint256 public constant REASON_COLLECT_FAILED = 1 << 6;
    uint256 public constant REASON_INVALID_SAMPLE_WINDOW = 1 << 7;

    uint8 internal constant STATUS_OK = 0;
    uint8 internal constant STATUS_CALL_FAILED = 1;

    struct CollectOutput {
        uint8 status;
        uint256 observedBlockNumber;
        uint256 escrowBalance;
        uint256 totalSupply;
        uint256 escrowRatioBps;
        bytes32 adapterCodehash;
        bytes32 tokenCodehash;
    }

    function collect() external view returns (bytes memory) {
        if (RSETH.code.length == 0 || RSETH_OFT_ADAPTER.code.length == 0) return _failed();
        try IERC20Like(RSETH).balanceOf(RSETH_OFT_ADAPTER) returns (uint256 escrowBalance) {
            try IERC20Like(RSETH).totalSupply() returns (uint256 totalSupply) {
                uint256 ratio = totalSupply == 0 ? 0 : escrowBalance * BPS / totalSupply;
                return abi.encode(
                    CollectOutput({
                        status: STATUS_OK,
                        observedBlockNumber: block.number,
                        escrowBalance: escrowBalance,
                        totalSupply: totalSupply,
                        escrowRatioBps: ratio,
                        adapterCodehash: RSETH_OFT_ADAPTER.codehash,
                        tokenCodehash: RSETH.codehash
                    })
                );
            } catch {
                return _failed();
            }
        } catch {
            return _failed();
        }
    }

    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        if (data.length < REQUIRED_SAMPLES) return (false, bytes(""));
        CollectOutput memory latest = abi.decode(data[0], (CollectOutput));
        if (!_validWindow(data)) {
            return (
                true,
                abi.encode(
                    SEVERITY_WARNING,
                    REASON_INVALID_SAMPLE_WINDOW,
                    RSETH_OFT_ADAPTER,
                    latest.observedBlockNumber,
                    abi.encode("invalid sample window")
                )
            );
        }

        CollectOutput memory previous = abi.decode(data[data.length - 1], (CollectOutput));
        uint256 reasons;
        if (latest.status != STATUS_OK) reasons |= REASON_COLLECT_FAILED;
        if (latest.adapterCodehash != previous.adapterCodehash) reasons |= REASON_ADAPTER_CODEHASH_DRIFT;
        if (latest.tokenCodehash != previous.tokenCodehash) reasons |= REASON_TOKEN_CODEHASH_DRIFT;
        if (latest.escrowRatioBps < MIN_ESCROW_RATIO_BPS) reasons |= REASON_ESCROW_UNDER_MINIMUM;

        uint256 outflow;
        if (previous.escrowBalance > latest.escrowBalance) {
            outflow = previous.escrowBalance - latest.escrowBalance;
            if (outflow >= LARGE_OUTFLOW_ABSOLUTE && outflow * BPS >= previous.escrowBalance * LARGE_OUTFLOW_BPS) {
                reasons |= REASON_BRIDGE_ESCROW_OUTFLOW;
            }
            if (outflow >= CRITICAL_OUTFLOW_ABSOLUTE) reasons |= REASON_CRITICAL_ESCROW_OUTFLOW;
        }
        if (previous.escrowRatioBps > latest.escrowRatioBps && previous.escrowRatioBps - latest.escrowRatioBps >= LARGE_OUTFLOW_BPS) {
            reasons |= REASON_ESCROW_RATIO_DROP;
        }

        if (reasons == 0) return (false, bytes(""));
        uint8 severity = _severity(reasons);
        return (
            true,
            abi.encode(
                severity,
                reasons,
                RSETH_OFT_ADAPTER,
                latest.observedBlockNumber,
                abi.encode(previous.escrowBalance, latest.escrowBalance, outflow, latest.totalSupply, latest.escrowRatioBps)
            )
        );
    }

    function _failed() internal view returns (bytes memory) {
        return abi.encode(
            CollectOutput({
                status: STATUS_CALL_FAILED,
                observedBlockNumber: block.number,
                escrowBalance: 0,
                totalSupply: 0,
                escrowRatioBps: 0,
                adapterCodehash: bytes32(0),
                tokenCodehash: bytes32(0)
            })
        );
    }

    function _severity(uint256 reasons) internal pure returns (uint8) {
        if ((reasons & (REASON_CRITICAL_ESCROW_OUTFLOW | REASON_ADAPTER_CODEHASH_DRIFT | REASON_TOKEN_CODEHASH_DRIFT)) != 0) {
            return SEVERITY_CRITICAL;
        }
        if ((reasons & (REASON_BRIDGE_ESCROW_OUTFLOW | REASON_ESCROW_RATIO_DROP | REASON_ESCROW_UNDER_MINIMUM)) != 0) {
            return SEVERITY_HIGH;
        }
        return SEVERITY_WARNING;
    }

    function _validWindow(bytes[] calldata data) internal pure returns (bool) {
        CollectOutput memory previous = abi.decode(data[0], (CollectOutput));
        for (uint256 i = 1; i < data.length; i++) {
            CollectOutput memory current = abi.decode(data[i], (CollectOutput));
            if (previous.observedBlockNumber <= current.observedBlockNumber) return false;
            if (previous.observedBlockNumber - current.observedBlockNumber > MAX_BLOCK_GAP) return false;
            previous = current;
        }
        return true;
    }
}


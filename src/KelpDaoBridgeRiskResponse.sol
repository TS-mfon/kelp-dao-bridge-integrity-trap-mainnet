// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract KelpDaoBridgeRiskResponse {
    address public immutable drosera;
    bool public bridgePauseModeEnabled;

    event KelpBridgeRiskHandled(
        uint8 indexed severity,
        uint256 indexed reasonBitmap,
        address indexed primaryTarget,
        uint256 blockNumber,
        bytes context
    );

    error OnlyDrosera();

    constructor(address drosera_) {
        drosera = drosera_;
    }

    function setBridgePauseModeEnabled(bool enabled) external {
        if (msg.sender != drosera) revert OnlyDrosera();
        bridgePauseModeEnabled = enabled;
    }

    function handleKelpBridgeRisk(
        uint8 severity,
        uint256 reasonBitmap,
        address primaryTarget,
        uint256 blockNumber,
        bytes calldata context
    ) external {
        if (msg.sender != drosera) revert OnlyDrosera();
        emit KelpBridgeRiskHandled(severity, reasonBitmap, primaryTarget, blockNumber, context);
    }
}


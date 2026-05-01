// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/KelpDaoBridgeIntegrityTrap.sol";
import "../src/KelpDaoBridgeRiskResponse.sol";

interface Vm {
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function roll(uint256 blockNumber) external;
    function prank(address sender) external;
}

contract TokenMock {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function setBalance(address account, uint256 value) external {
        balanceOf[account] = value;
    }

    function setTotalSupply(uint256 value) external {
        totalSupply = value;
    }
}

contract KelpDaoBridgeIntegrityTrapTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DROSERA = address(0xD005E7A);
    address internal constant RSETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address internal constant RSETH_OFT_ADAPTER = 0x85d456B2DfF1fd8245387C0BfB64Dfb700e98Ef3;

    function testHealthyBridgeEscrowDoesNotTrigger() public {
        KelpDaoBridgeIntegrityTrap trap = _deploy();
        bytes[] memory data = _samples(trap, 0);
        (bool ok,) = trap.shouldRespond(data);
        _assertFalse(ok, "healthy escrow should not trigger");
    }

    function testLargeBridgeEscrowOutflowTriggers() public {
        KelpDaoBridgeIntegrityTrap trap = _deploy();
        bytes[] memory data = _samples(trap, 116_500 ether);
        (bool ok, bytes memory payload) = trap.shouldRespond(data);
        _assertTrue(ok, "large forged-release style outflow should trigger");
        (uint8 severity, uint256 reasons,,,) = abi.decode(payload, (uint8, uint256, address, uint256, bytes));
        _assertEq(uint256(severity), uint256(trap.SEVERITY_CRITICAL()), "critical severity");
        _assertTrue((reasons & trap.REASON_BRIDGE_ESCROW_OUTFLOW()) != 0, "outflow reason");
        _assertTrue((reasons & trap.REASON_CRITICAL_ESCROW_OUTFLOW()) != 0, "critical outflow reason");
    }

    function testInvalidWindowTriggersInvalidWindowReason() public {
        KelpDaoBridgeIntegrityTrap trap = _deploy();
        bytes[] memory data = _samples(trap, 116_500 ether);
        bytes[] memory reversed = new bytes[](2);
        reversed[0] = data[1];
        reversed[1] = data[0];
        (bool ok, bytes memory payload) = trap.shouldRespond(reversed);
        _assertTrue(ok, "invalid window should return response payload");
        (, uint256 reasons,,,) = abi.decode(payload, (uint8, uint256, address, uint256, bytes));
        _assertTrue((reasons & trap.REASON_INVALID_SAMPLE_WINDOW()) != 0, "invalid window reason");
    }

    function testResponseOnlyDrosera() public {
        KelpDaoBridgeRiskResponse response = new KelpDaoBridgeRiskResponse(DROSERA);
        bool reverted;
        try response.handleKelpBridgeRisk(3, 1, address(0xBEEF), block.number, "") {}
        catch {
            reverted = true;
        }
        _assertTrue(reverted, "non-Drosera caller rejected");
        vm.prank(DROSERA);
        response.handleKelpBridgeRisk(3, 1, address(0xBEEF), block.number, "");
    }

    function _deploy() internal returns (KelpDaoBridgeIntegrityTrap trap) {
        vm.roll(1_000);
        TokenMock tokenImpl = new TokenMock();
        TokenMock adapterImpl = new TokenMock();
        vm.etch(RSETH, address(tokenImpl).code);
        vm.etch(RSETH_OFT_ADAPTER, address(adapterImpl).code);
        TokenMock(RSETH).setTotalSupply(650_000 ether);
        TokenMock(RSETH).setBalance(RSETH_OFT_ADAPTER, 250_000 ether);
        trap = new KelpDaoBridgeIntegrityTrap();
    }

    function _samples(KelpDaoBridgeIntegrityTrap trap, uint256 outflow) internal returns (bytes[] memory data) {
        data = new bytes[](2);
        data[1] = trap.collect();
        vm.roll(1_001);
        if (outflow > 0) {
            TokenMock(RSETH).setBalance(RSETH_OFT_ADAPTER, 250_000 ether - outflow);
        }
        data[0] = trap.collect();
    }

    function _assertTrue(bool value, string memory reason) internal pure {
        require(value, reason);
    }

    function _assertFalse(bool value, string memory reason) internal pure {
        require(!value, reason);
    }

    function _assertEq(uint256 a, uint256 b, string memory reason) internal pure {
        require(a == b, reason);
    }
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HumanResources} from "../src/HumanResources.sol";

interface ISubmission {
    function submit(address hrContract) external;
}

/// @notice Registers the deployed HumanResources contract with the coursework submission contract.
/// Must be sent from the same wallet that claimed faucet ETH.
/// HR_CONTRACT=<address> forge script script/Submit.s.sol --rpc-url $RPC_URL --account hr-deployer --broadcast
contract Submit is Script {
    ISubmission constant SUBMISSION = ISubmission(0x1e767Af5D01be07FA0Aa4367d8473957e58FAc4E);

    function run() external {
        address hrContract = vm.envAddress("HR_CONTRACT");
        // Guard against submitting a wallet or wrong address: it must be our deployed contract
        require(hrContract.code.length > 0, "HR_CONTRACT has no code");
        require(HumanResources(payable(hrContract)).hrManager() != address(0), "not a HumanResources contract");

        vm.startBroadcast();
        SUBMISSION.submit(hrContract);
        vm.stopBroadcast();

        console.log("Submitted", hrContract);
    }
}

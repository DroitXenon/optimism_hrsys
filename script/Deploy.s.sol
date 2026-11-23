// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HumanResources} from "../src/HumanResources.sol";

/// @notice Deploys HumanResources to Optimism. The HR manager defaults to the deployer;
/// set HR_MANAGER to use a different address.
/// forge script script/Deploy.s.sol --rpc-url $RPC_URL --account hr-deployer --broadcast
contract Deploy is Script {
    function run() external returns (HumanResources hr) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address manager = vm.envOr("HR_MANAGER", deployer);

        hr = new HumanResources(manager);
        vm.stopBroadcast();

        console.log("HumanResources deployed at", address(hr));
        console.log("hrManager", hr.hrManager());
    }
}

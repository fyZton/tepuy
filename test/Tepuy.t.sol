// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules as IRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Tepuy} from "../contracts/Tepuy.sol";

contract TepuyTest is Test {
    Tepuy token;
    address admin = makeAddr("admin");
    address emisor = makeAddr("emisor");
    address user = makeAddr("user");

    function setUp() public {
        token = new Tepuy(1 days, admin);
        bytes32 role = token.EMISOR();
        vm.prank(admin);
        token.grantRole(role, emisor);
    }

    function test_metadata() public view {
        assertEq(token.decimals(), 0);
        assertEq(token.name(), "Tepuy Demo");
        assertEq(token.symbol(), "TPUY");
    }

    function test_mintByEmisor() public {
        vm.prank(emisor);
        token.mint(user, 1000);
        assertEq(token.balanceOf(user), 1000);
        assertEq(token.totalSupply(), 1000);
    }

    function test_mintWithoutRoleReverts() public {
        bytes32 role = token.EMISOR();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role)
        );
        vm.prank(user);
        token.mint(user, 1);
    }

    function test_adminWithoutEmisorCannotMint() public {
        bytes32 role = token.EMISOR();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        vm.prank(admin);
        token.mint(user, 1);
    }

    function test_mintToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(emisor);
        token.mint(address(0), 1);
    }

    function test_nonAdminCannotGrantRole() public {
        bytes32 role = token.EMISOR();
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole));
        vm.prank(user);
        token.grantRole(role, user);
    }

    function test_revokedEmisorCannotMint() public {
        bytes32 role = token.EMISOR();
        vm.prank(admin);
        token.revokeRole(role, emisor);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, emisor, role));
        vm.prank(emisor);
        token.mint(user, 1);
    }

    function testFuzz_mintByNonEmisorReverts(address caller, uint256 amount) public {
        vm.assume(caller != emisor);
        bytes32 role = token.EMISOR();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
        vm.prank(caller);
        token.mint(user, amount);
    }

    function testFuzz_mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, 1e30);
        vm.prank(emisor);
        token.mint(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    function _roles() internal view returns (bytes32[6] memory) {
        return [token.EMISOR(), token.CUSTODIO(), token.AGENTE_KYC(), token.SUPERVISOR(), token.ORACULO(), token.RECUPERADOR()];
    }

    function test_rolesAreDistinct() public view {
        bytes32[6] memory r = _roles();
        for (uint256 i; i < 6; i++) {
            assertTrue(r[i] != token.DEFAULT_ADMIN_ROLE());
            for (uint256 j = i + 1; j < 6; j++) assertTrue(r[i] != r[j]);
        }
        assertEq(r[1], keccak256("CUSTODIO"));
        assertEq(r[2], keccak256("AGENTE_KYC"));
    }

    function test_onlyAdminGrantsAndRevokesEveryRole() public {
        bytes32[6] memory r = _roles();
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < 6; i++) {
            vm.prank(admin);
            token.grantRole(r[i], user);
            assertTrue(token.hasRole(r[i], user));
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole));
            token.revokeRole(r[i], user);
            vm.prank(admin);
            token.revokeRole(r[i], user);
            assertFalse(token.hasRole(r[i], user));
        }
    }

    function test_constructorRevertsBelowMinDelay() public {
        uint48 min = token.RETRASO_MINIMO();
        vm.expectRevert(abi.encodeWithSelector(Tepuy.RetrasoInsuficiente.selector, min - 1, min));
        new Tepuy(min - 1, admin);
        new Tepuy(min, admin);
    }

    function test_adminTransferFlowLeavesDeployerWithoutRoles() public {
        address deployer = makeAddr("deployer");
        Tepuy t = new Tepuy(1 days, deployer);
        bytes32[6] memory r = _roles();
        bytes32 adminRole = t.DEFAULT_ADMIN_ROLE();
        vm.startPrank(deployer);
        for (uint256 i; i < 6; i++) t.grantRole(r[i], makeAddr(vm.toString(i)));
        t.beginDefaultAdminTransfer(admin);
        vm.stopPrank();

        (, uint48 schedule) = t.pendingDefaultAdmin();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule));
        t.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(admin);
        t.acceptDefaultAdminTransfer();

        assertTrue(t.hasRole(adminRole, admin));
        assertFalse(t.hasRole(adminRole, deployer));
        for (uint256 i; i < 6; i++) assertFalse(t.hasRole(r[i], deployer));
    }

    function testFuzz_noRoleCannotGrantOrMint(address caller, uint8 idx) public {
        vm.assume(caller != admin && caller != emisor);
        bytes32 role = _roles()[idx % 6];
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 emisorRole = token.EMISOR();
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, adminRole));
        token.grantRole(role, caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, emisorRole));
        token.mint(caller, 1);
        vm.stopPrank();
    }

    function testFuzz_otherRoleHolderCannotMint(address holder, uint8 idx) public {
        vm.assume(holder != emisor);
        bytes32 role = _roles()[1 + idx % 5];
        vm.prank(admin);
        token.grantRole(role, holder);
        bytes32 emisorRole = token.EMISOR();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, holder, emisorRole));
        vm.prank(holder);
        token.mint(holder, 1);
    }

    function test_changeDelayBelowMinReverts() public {
        uint48 min = token.RETRASO_MINIMO();
        vm.expectRevert(abi.encodeWithSelector(Tepuy.RetrasoInsuficiente.selector, min - 1, min));
        vm.prank(admin);
        token.changeDefaultAdminDelay(min - 1);
        vm.prank(admin);
        token.changeDefaultAdminDelay(min);
    }

    function test_grantRevokeAdminRoleReverts() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        vm.expectRevert(IRules.AccessControlEnforcedDefaultAdminRules.selector);
        token.grantRole(adminRole, user);
        vm.expectRevert(IRules.AccessControlEnforcedDefaultAdminRules.selector);
        token.revokeRole(adminRole, admin);
        vm.stopPrank();
    }

    function test_renounceAdminOnlyAfterScheduledTransferToZero() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRules.AccessControlEnforcedDefaultAdminDelay.selector, 0));
        token.renounceRole(adminRole, admin);
        token.beginDefaultAdminTransfer(address(0));
        (, uint48 schedule) = token.pendingDefaultAdmin();
        vm.expectRevert(abi.encodeWithSelector(IRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule));
        token.renounceRole(adminRole, admin);
        vm.warp(schedule + 1);
        token.renounceRole(adminRole, admin);
        vm.stopPrank();
        assertEq(token.defaultAdmin(), address(0));
    }

    function test_cancelAdminTransfer() public {
        vm.startPrank(admin);
        token.beginDefaultAdminTransfer(user);
        token.cancelDefaultAdminTransfer();
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRules.AccessControlInvalidDefaultAdmin.selector, user));
        token.acceptDefaultAdminTransfer();
        assertEq(token.defaultAdmin(), admin);
    }
}

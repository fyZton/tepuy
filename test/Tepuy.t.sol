// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
}

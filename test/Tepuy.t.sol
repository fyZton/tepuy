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
    address kyc = makeAddr("kyc");
    address sup = makeAddr("sup");
    address otro = makeAddr("otro");
    address cust = makeAddr("cust");
    uint256 constant TOPE = type(uint128).max;

    function setUp() public {
        token = new Tepuy(1 days, admin);
        bytes32 role = token.EMISOR();
        vm.prank(admin);
        token.grantRole(role, emisor);
        bytes32 kycRole = token.AGENTE_KYC();
        vm.prank(admin);
        token.grantRole(kycRole, kyc);
        bytes32 supRole = token.SUPERVISOR();
        vm.prank(admin);
        token.grantRole(supRole, sup);
        vm.prank(kyc);
        token.setVerified(user, true);
        bytes32 custRole = token.CUSTODIO();
        vm.prank(admin);
        token.grantRole(custRole, cust);
        _attest(TOPE); // holgura para los demás tests; los del tope fijan su propio valor
    }

    function _attest(uint256 n) internal {
        vm.prank(cust);
        token.setAttestedShares(n);
    }

    function _freeze(address who, bool c) internal {
        vm.prank(sup);
        token.setAddressFrozen(who, c);
    }

    function _verify(address who) internal {
        vm.prank(kyc);
        token.setVerified(who, true);
    }

    function _unauth(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    function _mintTo(address to, uint256 n) internal {
        vm.prank(emisor);
        token.mint(to, n);
    }

    function test_mintToUnverifiedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, otro));
        _mintTo(otro, 1);
    }

    function test_transferToUnverifiedReverts() public {
        _mintTo(user, 10);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, otro));
        vm.prank(user);
        token.transfer(otro, 1);
    }

    function test_transferBetweenVerifiedWorks() public {
        _mintTo(user, 10);
        vm.prank(kyc);
        token.setVerified(otro, true);
        vm.prank(user);
        token.transfer(otro, 4);
        assertEq(token.balanceOf(otro), 4);
    }

    function test_revokedKycBlocksSendingAndReceiving() public {
        _mintTo(user, 10);
        vm.prank(kyc);
        token.setVerified(user, false);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, user));
        vm.prank(user);
        token.transfer(user, 1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, user));
        _mintTo(user, 1);
        assertEq(token.balanceOf(user), 10); // saldo bloqueado, no perdido
    }

    function test_transferFromRespectsKycNotSpender() public {
        address spender = makeAddr("spender"); // sin KYC: no hace falta
        _mintTo(user, 10);
        vm.prank(user);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, otro));
        vm.prank(spender);
        token.transferFrom(user, otro, 1);

        vm.prank(kyc);
        token.setVerified(otro, true);
        vm.prank(spender);
        token.transferFrom(user, otro, 1);
        assertEq(token.balanceOf(otro), 1);

        vm.prank(kyc);
        token.setVerified(user, false);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, user));
        vm.prank(spender);
        token.transferFrom(user, otro, 1);
    }

    function test_setVerifiedOnlyAgent() public {
        bytes32 role = token.AGENTE_KYC();
        _unauth(user, role);
        vm.prank(user);
        token.setVerified(otro, true);
        _unauth(admin, role);
        vm.prank(admin);
        token.setVerified(otro, true);
        _unauth(emisor, role);
        vm.prank(emisor);
        token.setVerified(otro, true);
    }

    function test_setVerifiedZeroReverts() public {
        vm.expectRevert(Tepuy.CuentaInvalida.selector);
        vm.prank(kyc);
        token.setVerified(address(0), true);
    }

    function test_setVerifiedEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Tepuy.VerificacionCambiada(otro, true, kyc);
        vm.prank(kyc);
        token.setVerified(otro, true);
        assertTrue(token.isVerified(otro));
    }

    function test_setVerifiedNoChangeEmitsNothing() public {
        vm.recordLogs();
        vm.prank(kyc);
        token.setVerified(user, true); // ya verificado
        vm.prank(kyc);
        token.setVerified(otro, false); // ya no verificado
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(token.isVerified(user));
        assertFalse(token.isVerified(otro));
    }

    function testFuzz_unverifiedNeverReceives(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != user);
        amount = bound(amount, 1, 1e30);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, to));
        _mintTo(to, amount);
        _mintTo(user, amount);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, to));
        vm.prank(user);
        token.transfer(to, amount);
    }

    function test_frozenCannotSendNorReceiveNorMint() public {
        _verify(otro);
        _mintTo(user, 10);
        _freeze(user, true);
        assertTrue(token.isVerified(user)); // KYC intacto
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, user));
        vm.prank(user);
        token.transfer(otro, 1);
        _mintTo(otro, 5);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, user));
        vm.prank(otro);
        token.transfer(user, 1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, user));
        _mintTo(user, 1);
        assertEq(token.balanceOf(user), 10);
    }

    function test_frozenRespectedByTransferFrom() public {
        address spender = makeAddr("spender");
        _verify(otro);
        _mintTo(user, 10);
        vm.prank(user);
        token.approve(spender, 10);
        _freeze(user, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, user));
        vm.prank(spender);
        token.transferFrom(user, otro, 1);
        _freeze(user, false);
        _freeze(otro, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, otro));
        vm.prank(spender);
        token.transferFrom(user, otro, 1);
    }

    function test_unfreezeRestores() public {
        _verify(otro);
        _mintTo(user, 10);
        _freeze(user, true);
        _freeze(user, false);
        vm.prank(user);
        token.transfer(otro, 3);
        assertEq(token.balanceOf(otro), 3);
        assertFalse(token.isFrozen(user));
    }

    // Orden documentado: KYC antes que congelamiento.
    function test_kycCheckedBeforeFreeze() public {
        _mintTo(user, 10);
        _freeze(otro, true); // congelado y sin KYC
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, otro));
        vm.prank(user);
        token.transfer(otro, 1);
        _freeze(user, true);
        vm.prank(kyc);
        token.setVerified(user, false); // congelado y sin KYC
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, user));
        vm.prank(user);
        token.transfer(otro, 1);
    }

    function test_setAddressFrozenOnlySupervisor() public {
        bytes32 role = token.SUPERVISOR();
        _unauth(user, role);
        vm.prank(user);
        token.setAddressFrozen(otro, true);
        _unauth(admin, role);
        vm.prank(admin);
        token.setAddressFrozen(otro, true);
        _unauth(kyc, role);
        vm.prank(kyc);
        token.setAddressFrozen(otro, true);
        _unauth(emisor, role);
        vm.prank(emisor);
        token.setAddressFrozen(otro, true);
    }

    function test_setAddressFrozenZeroReverts() public {
        vm.expectRevert(Tepuy.CuentaInvalida.selector);
        vm.prank(sup);
        token.setAddressFrozen(address(0), true);
    }

    function test_setAddressFrozenEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Tepuy.CongelamientoCambiado(otro, true, sup);
        _freeze(otro, true);
        assertTrue(token.isFrozen(otro));
    }

    function test_setAddressFrozenNoChangeEmitsNothing() public {
        vm.recordLogs();
        _freeze(user, false);
        _freeze(otro, false);
        assertEq(vm.getRecordedLogs().length, 0);
        _freeze(user, true);
        vm.recordLogs();
        _freeze(user, true);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(token.isFrozen(user));
    }

    function testFuzz_frozenNeverMovesNorReceives(address who, uint256 amount) public {
        vm.assume(who != address(0) && who != user);
        amount = bound(amount, 1, 1e30);
        _verify(who);
        _mintTo(user, amount);
        _freeze(who, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, who));
        vm.prank(user);
        token.transfer(who, amount);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, who));
        _mintTo(who, amount);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, who));
        vm.prank(who);
        token.transfer(user, 0);
    }

    // Congelar es sobre el titular: un spender congelado sí mueve fondos entre cuentas activas (ERC-3643).
    function test_frozenSpenderCanStillMoveBetweenActive() public {
        address spender = makeAddr("spender");
        _verify(otro);
        _mintTo(user, 10);
        vm.prank(user);
        token.approve(spender, 10);
        _freeze(spender, true);
        vm.prank(spender);
        token.transferFrom(user, otro, 4);
        assertEq(token.balanceOf(otro), 4);
    }

    function testFuzz_transferFromFrozenReverts(address who, uint256 amount, bool owner) public {
        vm.assume(who != address(0) && who != user);
        amount = bound(amount, 1, 1e30);
        address spender = makeAddr("spender");
        _verify(who);
        _mintTo(user, amount);
        _mintTo(who, amount);
        vm.prank(user);
        token.approve(spender, amount);
        vm.prank(who);
        token.approve(spender, amount);
        address frozen = owner ? user : who;
        _freeze(frozen, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, frozen));
        vm.prank(spender);
        token.transferFrom(user, who, amount);
        // Descongelar restaura.
        _freeze(frozen, false);
        vm.prank(spender);
        token.transferFrom(user, who, amount);
        assertEq(token.balanceOf(who), 2 * amount);
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
        vm.prank(kyc);
        token.setVerified(to, true);
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

    function test_startsAtZeroAndMintBlocked() public {
        Tepuy t = new Tepuy(1 days, admin);
        bytes32 role = t.EMISOR();
        vm.prank(admin);
        t.grantRole(role, emisor);
        assertEq(t.accionesAtestiguadas(), 0);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 1, 0));
        vm.prank(emisor);
        t.mint(user, 1);
    }

    function test_mintUpToExactCapThenOneMoreReverts() public {
        _attest(10);
        _mintTo(user, 10);
        assertEq(token.accionesAtestiguadas(), token.totalSupply());
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 1, 0));
        _mintTo(user, 1);
    }

    function test_mintOverCapReportsAvailable() public {
        _attest(10);
        _mintTo(user, 4);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 7, 6));
        _mintTo(user, 7);
    }

    function test_setAttestedOnlyCustodio() public {
        bytes32 role = token.CUSTODIO();
        address[3] memory otros = [admin, emisor, otro];
        for (uint256 i; i < 3; i++) {
            _unauth(otros[i], role);
            vm.prank(otros[i]);
            token.setAttestedShares(1);
        }
    }

    function test_lowerBelowSupplyReverts() public {
        _attest(10);
        _mintTo(user, 6);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.AtestiguacionInsuficiente.selector, 5, 6));
        _attest(5);
        assertEq(token.accionesAtestiguadas(), 10);
    }

    function test_lowerToExactSupplyWorks() public {
        _attest(10);
        _mintTo(user, 6);
        _attest(6);
        assertEq(token.accionesAtestiguadas(), 6);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 1, 0));
        _mintTo(user, 1);
    }

    function test_raiseAllowsMoreMint() public {
        _attest(5);
        _mintTo(user, 5);
        _attest(8);
        _mintTo(user, 3);
        assertEq(token.totalSupply(), 8);
    }

    function test_attestEmitsEvent() public {
        _attest(5);
        vm.expectEmit(true, false, false, true, address(token));
        emit Tepuy.AtestiguacionCambiada(5, 9, cust);
        _attest(9);
    }

    function test_attestNoChangeEmitsNothing() public {
        _attest(5);
        vm.recordLogs();
        _attest(5);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testFuzz_mintRespectsCap(uint256 tope, uint256 amount) public {
        _attest(tope);
        if (amount > tope) vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, amount, tope));
        _mintTo(user, amount);
        assertLe(token.totalSupply(), token.accionesAtestiguadas());
    }

    function testFuzz_cannotLowerBelowSupply(uint256 supply, uint256 nuevas) public {
        supply = bound(supply, 1, 1e30);
        nuevas = bound(nuevas, 0, supply - 1);
        _mintTo(user, supply);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.AtestiguacionInsuficiente.selector, nuevas, supply));
        _attest(nuevas);
    }

    /// El tope se evalúa antes que el KYC del receptor.
    function test_capCheckedBeforeKyc() public {
        _attest(1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 2, 1));
        _mintTo(otro, 2); // otro sin KYC y fuera de tope
    }
}

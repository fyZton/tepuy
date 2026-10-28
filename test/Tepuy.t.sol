// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules as IRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
    address rec = makeAddr("rec");
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
        bytes32 recRole = token.RECUPERADOR();
        vm.prank(admin);
        token.grantRole(recRole, rec);
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
        tope = bound(tope, 0, type(uint208).max); // setAttestedShares rechaza más (AtestiguacionExcesiva)
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

    function _pause() internal {
        vm.prank(sup);
        token.pause();
    }

    function test_pauseOnlySupervisor() public {
        bytes32 role = token.SUPERVISOR();
        address[5] memory otros = [admin, kyc, cust, emisor, otro];
        for (uint256 i; i < 5; i++) {
            _unauth(otros[i], role);
            vm.prank(otros[i]);
            token.pause();
        }
        _pause();
        for (uint256 i; i < 5; i++) {
            _unauth(otros[i], role);
            vm.prank(otros[i]);
            token.unpause();
        }
        assertTrue(token.paused());
    }

    function test_pausedBlocksMintTransferTransferFrom() public {
        address spender = makeAddr("spender");
        _verify(otro);
        _mintTo(user, 10);
        vm.prank(user);
        token.approve(spender, 10);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mintTo(user, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        token.transfer(otro, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(spender);
        token.transferFrom(user, otro, 1);
        assertEq(token.balanceOf(user), 10);
        assertEq(token.totalSupply(), 10);
    }

    function test_pausedAllowsKycFreezeAttest() public {
        _pause();
        vm.prank(kyc);
        token.setVerified(otro, true);
        assertTrue(token.isVerified(otro));
        _freeze(otro, true);
        assertTrue(token.isFrozen(otro));
        _attest(77);
        assertEq(token.accionesAtestiguadas(), 77);
    }

    function test_unpauseRestores() public {
        _verify(otro);
        _mintTo(user, 10);
        _pause();
        vm.prank(sup);
        token.unpause();
        assertFalse(token.paused());
        vm.prank(user);
        token.transfer(otro, 4);
        _mintTo(user, 1);
        assertEq(token.balanceOf(otro), 4);
        assertEq(token.balanceOf(user), 7);
    }

    function test_pauseTwiceAndUnpauseWithoutPauseRevert() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(sup);
        token.unpause();
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _pause();
    }

    function test_pauseEmitsEvents() public {
        vm.expectEmit(false, false, false, true, address(token));
        emit Pausable.Paused(sup);
        _pause();
        vm.expectEmit(false, false, false, true, address(token));
        emit Pausable.Unpaused(sup);
        vm.prank(sup);
        token.unpause();
    }

    /// La pausa se evalúa antes que KYC y congelamiento; el tope sigue siendo previo a todo en mint.
    function test_pauseCheckedBeforeKycAndFreeze() public {
        _mintTo(user, 10);
        _freeze(user, true);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mintTo(otro, 1); // otro sin KYC
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        token.transfer(otro, 1); // congelada y receptor sin KYC
        _attest(10);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 1, 0));
        _mintTo(user, 1);
    }

    /// Ambos verificados, solo el emisor congelado: la pausa gana sobre el congelamiento.
    function test_pauseBeatsFreezeWhenBothVerified() public {
        _verify(otro);
        _mintTo(user, 10);
        _freeze(user, true);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        token.transfer(otro, 1);
    }

    function testFuzz_pausedNeverMoves(address to, uint256 amount) public {
        vm.assume(to != address(0));
        _mintTo(user, 10);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        token.transfer(to, amount);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mintTo(to, amount % 100);
        assertEq(token.totalSupply(), 10);
    }

    // ---- S7: transferencia forzada y recuperación ----

    string constant M = "orden 123";

    function _forzar(address from, address to, uint256 n) internal {
        vm.prank(rec);
        token.forcedTransfer(from, to, n, M);
    }

    function _recuperar(address perdida, address nueva) internal {
        vm.prank(rec);
        token.recoveryAddress(perdida, nueva, M);
    }

    function test_forcedAndRecoveryOnlyRecuperador() public {
        bytes32 role = token.RECUPERADOR();
        _verify(otro);
        _mintTo(user, 10);
        address[6] memory otros = [admin, sup, kyc, cust, emisor, otro];
        for (uint256 i; i < 6; i++) {
            _unauth(otros[i], role);
            vm.prank(otros[i]);
            token.forcedTransfer(user, otro, 1, M);
            _unauth(otros[i], role);
            vm.prank(otros[i]);
            token.recoveryAddress(user, otro, M);
        }
        assertEq(token.balanceOf(user), 10);
    }

    function test_forcedFromFrozenUnverifiedAndPaused() public {
        _verify(otro);
        _mintTo(user, 10);
        _freeze(user, true);
        _pause();
        vm.prank(kyc);
        token.setVerified(user, false);
        vm.expectEmit(true, true, true, true);
        emit Tepuy.TransferenciaForzada(user, otro, 4, M, rec);
        _forzar(user, otro, 4);
        assertEq(token.balanceOf(user), 6);
        assertEq(token.balanceOf(otro), 4);
        assertEq(token.totalSupply(), 10);
    }

    function test_forcedReceiverRules() public {
        _mintTo(user, 10);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, otro));
        _forzar(user, otro, 1);
        _verify(otro);
        _freeze(otro, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, otro));
        _forzar(user, otro, 1);
        vm.expectRevert(Tepuy.CuentaInvalida.selector);
        _forzar(user, address(0), 1);
        assertEq(token.balanceOf(user), 10);
    }

    function test_forcedInvalidArgs() public {
        _verify(otro);
        _mintTo(user, 10);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentasIguales.selector, user));
        _forzar(user, user, 1);
        vm.expectRevert(Tepuy.MontoCero.selector);
        _forzar(user, otro, 0);
        vm.expectRevert(Tepuy.MotivoVacio.selector);
        vm.prank(rec);
        token.forcedTransfer(user, otro, 1, "");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 10, 11));
        _forzar(user, otro, 11);
    }

    /// Origen address(0) sería una emisión sin tope: debe rechazarse.
    function test_forcedCannotMint() public {
        vm.expectRevert(Tepuy.CuentaInvalida.selector);
        _forzar(address(0), user, 1);
        assertEq(token.totalSupply(), 0);
    }

    function test_recoveryMovesAllFreezesAndUnverifies() public {
        _verify(otro);
        _mintTo(user, 10);
        _pause();
        vm.expectEmit(true, true, true, true);
        emit Tepuy.CuentaRecuperada(user, otro, 10, M, rec);
        _recuperar(user, otro);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(otro), 10);
        assertTrue(token.isFrozen(user));
        assertFalse(token.isVerified(user));
        assertEq(token.totalSupply(), 10);
        assertEq(token.accionesAtestiguadas(), TOPE);
    }

    function test_recoveryFromAlreadyFrozenUnverified() public {
        _verify(otro);
        _mintTo(user, 10);
        _freeze(user, true);
        vm.prank(kyc);
        token.setVerified(user, false);
        _recuperar(user, otro);
        assertEq(token.balanceOf(otro), 10);
        assertTrue(token.isFrozen(user));
    }

    function test_recoveryReverts() public {
        _verify(otro);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.SinSaldo.selector, user));
        _recuperar(user, otro);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.SinSaldo.selector, address(0)));
        _recuperar(address(0), otro);
        _mintTo(user, 10);
        address nueva = makeAddr("nueva");
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, nueva));
        _recuperar(user, nueva);
        _freeze(otro, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, otro));
        _recuperar(user, otro);
        vm.expectRevert(Tepuy.CuentaInvalida.selector);
        _recuperar(user, address(0));
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentasIguales.selector, user));
        _recuperar(user, user);
        vm.expectRevert(Tepuy.MotivoVacio.selector);
        vm.prank(rec);
        token.recoveryAddress(user, otro, "");
        assertEq(token.balanceOf(user), 10);
        assertFalse(token.isFrozen(user));
    }

    function test_normalTransfersStillBlockedAfterS7() public {
        _verify(otro);
        _mintTo(user, 10);
        _freeze(user, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaCongelada.selector, user));
        vm.prank(user);
        token.transfer(otro, 1);
        _freeze(user, false);
        _forzar(user, otro, 1);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        token.transfer(otro, 1);
        _forzar(user, otro, 1); // sigue funcionando en pausa
        _recuperar(user, otro);
        assertEq(token.balanceOf(otro), 10);
        _unpause();
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, user)); // la clave recuperada ya no mueve nada
        vm.prank(user);
        token.transfer(otro, 1);
    }

    function _unpause() internal {
        vm.prank(sup);
        token.unpause();
    }

    function testFuzz_forcedKeepsSupply(uint256 n) public {
        _verify(otro);
        _mintTo(user, 1000);
        _freeze(user, true);
        _pause();
        n = bound(n, 1, 1000);
        _forzar(user, otro, n);
        assertEq(token.totalSupply(), 1000);
        assertEq(token.balanceOf(user) + token.balanceOf(otro), 1000);
    }

    function test_recoveryIsOneWay() public {
        _verify(otro);
        _mintTo(user, 10);
        assertFalse(token.isRecovered(user));
        _recuperar(user, otro);
        assertTrue(token.isRecovered(user));
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaYaRecuperada.selector, user));
        vm.prank(kyc);
        token.setVerified(user, true);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaYaRecuperada.selector, user));
        vm.prank(sup);
        token.setAddressFrozen(user, false);
        // Cerrar (desverificar/congelar) sigue permitido y sin efecto.
        vm.prank(kyc);
        token.setVerified(user, false);
        _freeze(user, true);
        assertTrue(token.isFrozen(user));
        assertFalse(token.isVerified(user));
    }

    /// Fondos recuperados a una cuenta que luego se congela se rescatan por forzada; la recuperada puede ser origen.
    function test_forcedRescueAfterRecovery() public {
        address c = makeAddr("c");
        _verify(otro);
        _verify(c);
        _mintTo(user, 10);
        _recuperar(user, otro);
        _freeze(otro, true);
        _recuperar(otro, c);
        assertEq(token.balanceOf(c), 10);
        assertTrue(token.isRecovered(otro));
    }

    function test_motivoLength() public {
        _verify(otro);
        _mintTo(user, 10);
        bytes memory ok = new bytes(256);
        for (uint256 i; i < 256; i++) ok[i] = "a";
        vm.prank(rec);
        token.forcedTransfer(user, otro, 1, string(ok));
        vm.expectRevert(abi.encodeWithSelector(Tepuy.MotivoLargo.selector, 257));
        vm.prank(rec);
        token.forcedTransfer(user, otro, 1, string.concat(string(ok), "a"));
        vm.expectRevert(abi.encodeWithSelector(Tepuy.MotivoLargo.selector, 257));
        vm.prank(rec);
        token.recoveryAddress(user, otro, string.concat(string(ok), "a"));
    }
}

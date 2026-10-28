// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Tepuy} from "../contracts/Tepuy.sol";

// S11: interacciones entre partes (S1-S10) y límites aritméticos.
contract TepuyEndurecimientoTest is Test {
    Tepuy token;
    address admin = makeAddr("admin");
    address emi = makeAddr("emi");
    address kyc = makeAddr("kyc");
    address sup = makeAddr("sup");
    address cust = makeAddr("cust");
    address rec = makeAddr("rec");
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");
    uint208 constant MAX = type(uint208).max;

    function setUp() public {
        token = new Tepuy(1 days, admin);
        bytes32[5] memory rs = [token.EMISOR(), token.AGENTE_KYC(), token.SUPERVISOR(), token.CUSTODIO(), token.RECUPERADOR()];
        address[5] memory qs = [emi, kyc, sup, cust, rec];
        vm.startPrank(admin);
        for (uint256 i; i < 5; i++) token.grantRole(rs[i], qs[i]);
        vm.stopPrank();
        _verify(a);
        _verify(b);
        _verify(c);
        vm.prank(cust);
        token.setAttestedShares(1000);
    }

    function _verify(address who) internal {
        vm.prank(kyc);
        token.setVerified(who, true);
    }

    function _mint(address to, uint256 n) internal {
        vm.prank(emi);
        token.mint(to, n);
    }

    function _snap() internal returns (uint256 id) {
        vm.roll(block.number + 1);
        vm.prank(emi);
        id = token.snapshot();
        vm.roll(block.number + 1);
    }

    function _div(uint256 id, uint256 n, uint256 d) internal {
        vm.prank(emi);
        token.declararDividendo(id, n, d);
    }

    function _pagar(uint256 id, address who) internal {
        address[] memory ts = new address[](1);
        ts[0] = who;
        vm.prank(emi);
        token.distribuirDividendo(id, ts);
    }

    function _unauth(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    // Forzada tras el corte: el dividendo sigue el saldo del corte, no el actual.
    function test_dividendAfterForcedTransferUsesCutBalance() public {
        _mint(a, 100);
        uint256 id = _snap();
        _div(id, 1, 10);
        vm.prank(rec);
        token.forcedTransfer(a, b, 100, "orden");
        _pagar(id, a);
        assertEq(token.balanceOf(a), 10);
        assertEq(token.balanceOf(b), 100);
        assertEq(token.totalSupply(), 110);
    }

    // Recuperación en pausa y dividendo después: en pausa el lote revierte; luego paga al destino.
    function test_recoveryInPauseThenDividend() public {
        _mint(a, 100);
        uint256 id = _snap();
        _div(id, 1, 1);
        vm.prank(sup);
        token.pause();
        vm.prank(rec);
        token.recoveryAddress(a, b, "perdida");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _pagar(id, a);
        vm.prank(sup);
        token.unpause();
        _pagar(id, a);
        assertEq(token.balanceOf(b), 200);
        assertEq(token.balanceOf(a), 0);
        assertTrue(token.isRecovered(a));
    }

    // Atestiguación al mínimo (= suministro): el snapshot funciona, el dividendo revierte hasta subirla.
    function test_attestationAtMinimumBlocksDividendNotSnapshot() public {
        _mint(a, 100);
        vm.prank(cust);
        token.setAttestedShares(100);
        uint256 id = _snap();
        _div(id, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 100, 0));
        _pagar(id, a);
        assertFalse(token.dividendoPagado(id, a));
        vm.prank(cust);
        token.setAttestedShares(200);
        _pagar(id, a);
        assertEq(token.totalSupply(), 200);
        vm.prank(cust);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.AtestiguacionInsuficiente.selector, 199, 200));
        token.setAttestedShares(199);
    }

    // Lotes separados: se revoca EMISOR entre ellos, el segundo revierte, se re-otorga y no paga doble.
    function test_roleRevokedBetweenBatches() public {
        _mint(a, 100);
        _mint(b, 100);
        uint256 id = _snap();
        _div(id, 1, 10);
        _pagar(id, a);
        bytes32 r = token.EMISOR();
        vm.prank(admin);
        token.revokeRole(r, emi);
        _unauth(emi, r);
        _pagar(id, b);
        vm.prank(admin);
        token.grantRole(r, emi);
        _pagar(id, a);
        _pagar(id, b);
        assertEq(token.balanceOf(a), 110);
        assertEq(token.balanceOf(b), 110);
        assertEq(token.totalSupply(), 220);
    }

    // Traspaso del admin en curso: no toca los roles operativos; el viejo admin pierde el poder al aceptar.
    function test_adminHandoverMidOperations() public {
        _mint(a, 100);
        uint256 id = _snap();
        _div(id, 1, 10);
        address nuevo = makeAddr("nuevo");
        vm.prank(admin);
        token.beginDefaultAdminTransfer(nuevo);
        _pagar(id, a);
        assertEq(token.balanceOf(a), 110);
        skip(2 days);
        vm.prank(nuevo);
        token.acceptDefaultAdminTransfer();
        bytes32 r = token.EMISOR();
        _unauth(admin, bytes32(0)); // primero la expectativa; el prank va justo antes de la llamada
        vm.prank(admin);
        token.revokeRole(r, emi);
        vm.prank(nuevo);
        token.revokeRole(r, emi);
        _unauth(emi, r);
        vm.prank(emi);
        token.snapshot();
    }

    // KYC retirado al destino: se omite sin pagar; al restaurarlo se paga una sola vez.
    function test_kycRevokedBeforeDividendThenRestored() public {
        _mint(a, 100);
        uint256 id = _snap();
        _div(id, 1, 10);
        vm.prank(kyc);
        token.setVerified(a, false);
        _pagar(id, a);
        assertFalse(token.dividendoPagado(id, a));
        assertEq(token.totalSupply(), 100);
        _verify(a);
        _pagar(id, a);
        _pagar(id, a);
        assertEq(token.totalSupply(), 110);
    }

    // Una recuperada no vuelve: ni KYC, ni descongelar, ni recibir (mint, transfer, forzada).
    function test_recoveredNeverComesBack() public {
        _mint(a, 10);
        vm.prank(rec);
        token.recoveryAddress(a, b, "perdida");
        vm.prank(kyc);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaYaRecuperada.selector, a));
        token.setVerified(a, true);
        vm.prank(sup);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.CuentaYaRecuperada.selector, a));
        token.setAddressFrozen(a, false);
        vm.prank(emi);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, a));
        token.mint(a, 1);
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, a));
        token.transfer(a, 1);
        vm.prank(rec);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.NoVerificado.selector, a));
        token.forcedTransfer(b, a, 1, "x");
        assertEq(token.balanceOf(a), 0);
    }

    // Pausa: no mueve ni emite; KYC, congelar y forzada siguen.
    function test_pauseScope() public {
        _mint(a, 10);
        vm.prank(sup);
        token.pause();
        vm.prank(a);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(b, 1);
        vm.prank(emi);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mint(b, 1);
        _verify(makeAddr("d"));
        vm.prank(sup);
        token.setAddressFrozen(a, true);
        vm.prank(rec);
        token.forcedTransfer(a, b, 10, "orden");
        assertEq(token.balanceOf(b), 10);
    }

    // Mint en los límites del tope: 0, 1, tope y tope + 1.
    function testFuzz_mintBoundaries(uint256 tope) public {
        tope = bound(tope, 1, MAX);
        vm.prank(cust);
        token.setAttestedShares(tope);
        _mint(a, 0);
        assertEq(token.totalSupply(), 0);
        _mint(a, 1);
        _mint(a, tope - 1);
        assertEq(token.totalSupply(), tope);
        vm.prank(emi);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 1, 0));
        token.mint(a, 1);
    }

    function test_mintUint208MaxAndOver() public {
        vm.prank(cust);
        token.setAttestedShares(MAX);
        _mint(a, MAX);
        assertEq(token.totalSupply(), MAX);
        vm.prank(cust);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.AtestiguacionExcesiva.selector, uint256(MAX) + 1));
        token.setAttestedShares(uint256(MAX) + 1);
        vm.prank(emi);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, type(uint256).max, 0));
        token.mint(b, type(uint256).max);
    }

    // Forzada en límites: 0, 1, saldo, saldo + 1 y hasta uint208 max.
    function testFuzz_forcedBoundaries(uint256 saldo, uint256 monto) public {
        saldo = bound(saldo, 1, MAX);
        vm.prank(cust);
        token.setAttestedShares(MAX);
        _mint(a, saldo);
        monto = bound(monto, 0, saldo + 1);
        bool ok = monto != 0 && monto <= saldo;
        vm.prank(rec);
        if (monto == 0) vm.expectRevert(Tepuy.MontoCero.selector);
        else if (!ok) vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, a, saldo, monto));
        token.forcedTransfer(a, b, monto, "orden");
        assertEq(token.balanceOf(b), ok ? monto : 0);
        assertEq(token.totalSupply(), saldo);
    }

    // Dividendo con numerador/denominador enormes: o paga el piso dentro del cupo o revierte entero sin marcar.
    function testFuzz_dividendBoundaries(uint256 saldo, uint256 n, uint256 d, uint256 cupo) public {
        saldo = bound(saldo, 1, MAX);
        n = bound(n, 1, type(uint256).max);
        d = bound(d, 1, type(uint256).max);
        vm.prank(cust);
        token.setAttestedShares(MAX);
        _mint(a, saldo);
        uint256 id = _snap();
        _div(id, n, d);
        cupo = bound(cupo, saldo, MAX);
        vm.prank(cust);
        token.setAttestedShares(cupo);
        address[] memory ts = new address[](1);
        ts[0] = a;
        vm.prank(emi);
        try token.distribuirDividendo(id, ts) {
            assertTrue(token.dividendoPagado(id, a));
            assertLe(token.totalSupply(), cupo);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(sel == Tepuy.TopeExcedido.selector || sel == bytes4(0x4e487b71) /* Panic: desborde de mulDiv */, "revert inesperado");
            assertFalse(token.dividendoPagado(id, a));
            assertEq(token.totalSupply(), saldo);
        }
    }
}

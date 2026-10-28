// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Tepuy} from "../contracts/Tepuy.sol";

// Pruebas de S10 (dividendo en acciones) en archivo aparte.
contract TepuyDividendoTest is Test {
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
        token.setAttestedShares(1_000_000);
    }

    function _verify(address who) internal {
        vm.prank(kyc);
        token.setVerified(who, true);
    }

    function _mint(address to, uint256 n) internal {
        vm.prank(emi);
        token.mint(to, n);
    }

    // Snapshot en un bloque nuevo: lo minteado antes queda dentro del corte.
    function _snap() internal returns (uint256) {
        vm.roll(block.number + 1);
        vm.prank(emi);
        uint256 id = token.snapshot();
        vm.roll(block.number + 1);
        return id;
    }

    function _declarar(uint256 id, uint256 n, uint256 d) internal {
        vm.prank(emi);
        token.declararDividendo(id, n, d);
    }

    function _pagar(uint256 id, address[] memory ts) internal {
        vm.prank(emi);
        token.distribuirDividendo(id, ts);
    }

    function _uno(address x) internal pure returns (address[] memory ts) {
        ts = new address[](1);
        ts[0] = x;
    }

    function _dos(address x, address y) internal pure returns (address[] memory ts) {
        ts = new address[](2);
        ts[0] = x;
        ts[1] = y;
    }

    // a tiene 1000 en el corte.
    function _snapConDividendo(uint256 n, uint256 d) internal returns (uint256 id) {
        _mint(a, 1000);
        id = _snap();
        _declarar(id, n, d);
    }

    function test_onlyEmisor() public {
        uint256 id = _snapConDividendo(1, 1);
        bytes32 r = token.EMISOR();
        address[4] memory otros = [admin, rec, a, address(this)];
        for (uint256 i; i < 4; i++) {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, otros[i], r));
            vm.prank(otros[i]);
            token.declararDividendo(id, 1, 1);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, otros[i], r));
            vm.prank(otros[i]);
            token.distribuirDividendo(id, _uno(a));
        }
    }

    function test_declareTwiceReverts() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.DividendoYaDeclarado.selector, id));
        _declarar(id, 2, 1);
        (uint256 n, uint256 d) = token.dividendo(id);
        assertEq(n, 1);
        assertEq(d, 10);
    }

    function test_declareEvent() public {
        _mint(a, 5);
        uint256 id = _snap();
        vm.expectEmit(true, true, false, true);
        emit Tepuy.DividendoDeclarado(id, 3, 7, emi);
        _declarar(id, 3, 7);
    }

    function test_invalidProportionAndMissingSnapshot() public {
        _snapConDividendo(1, 1);
        uint256 id2 = _snap();
        vm.expectRevert(abi.encodeWithSelector(Tepuy.ProporcionInvalida.selector, 0, 1));
        _declarar(id2, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.ProporcionInvalida.selector, 1, 0));
        _declarar(id2, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.SnapshotInexistente.selector, 0));
        _declarar(0, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.SnapshotInexistente.selector, id2 + 1));
        _declarar(id2 + 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.DividendoNoDeclarado.selector, id2));
        _pagar(id2, _uno(a));
        vm.expectRevert(abi.encodeWithSelector(Tepuy.DividendoNoDeclarado.selector, id2 + 5));
        _pagar(id2 + 5, _uno(a));
    }

    function test_oneToOne() public {
        uint256 id = _snapConDividendo(1, 1);
        vm.expectEmit(true, true, true, true);
        emit Tepuy.DividendoPagado(id, a, a, 1000);
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(a), 2000);
        assertEq(token.totalSupply(), 2000);
        assertTrue(token.dividendoPagado(id, a));
    }

    function test_oneToTenWithFractions() public {
        _mint(a, 1000);
        _mint(b, 15);
        _mint(c, 9);
        uint256 id = _snap();
        _declarar(id, 1, 10);
        vm.recordLogs();
        _pagar(id, _uno(b));
        Vm.Log[] memory l = vm.getRecordedLogs();
        assertEq(l.length, 3); // Transfer, DividendoPagado, FraccionPendiente
        assertEq(l[2].topics[0], Tepuy.FraccionPendiente.selector);
        assertEq(l[2].topics[3], bytes32(uint256(uint160(b)))); // destino
        assertEq(abi.decode(l[2].data, (uint256)), 5);
        _pagar(id, _dos(a, c));
        assertEq(token.balanceOf(a), 1100);
        assertEq(token.balanceOf(b), 16);
        assertEq(token.balanceOf(c), 9); // 0 acciones nuevas
        assertTrue(token.dividendoPagado(id, c)); // saldado en cero
    }

    function test_zeroAmountEmitsFractionOnly() public {
        _mint(c, 9);
        uint256 id = _snap();
        _declarar(id, 1, 10);
        vm.expectEmit(true, true, false, true);
        emit Tepuy.FraccionPendiente(id, c, c, 9);
        _pagar(id, _uno(c));
    }

    function test_noFractionEventWhenExact() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.recordLogs();
        _pagar(id, _uno(a));
        assertEq(vm.getRecordedLogs().length, 2); // Transfer y DividendoPagado
    }

    function test_idempotent() public {
        uint256 id = _snapConDividendo(1, 10);
        _pagar(id, _dos(a, a)); // repetido dentro del lote
        _pagar(id, _dos(a, b));
        vm.recordLogs();
        _pagar(id, _uno(a));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.balanceOf(a), 1100);
        assertEq(token.totalSupply(), 1100);
    }

    function test_laterMovementsUseCut() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.prank(a);
        token.transfer(b, 1000); // tras el corte
        _mint(c, 500); // emitido tras el corte: no cobra
        _pagar(id, _dos(a, b));
        _pagar(id, _uno(c));
        assertEq(token.balanceOf(a), 100);
        assertEq(token.balanceOf(b), 1000);
        assertEq(token.balanceOf(c), 500);
    }

    function test_recoveredPaysNewAccount() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.prank(rec);
        token.recoveryAddress(a, b, "orden");
        vm.expectEmit(true, true, true, true);
        emit Tepuy.DividendoPagado(id, a, b, 100);
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(a), 0);
        assertEq(token.balanceOf(b), 1100);
        assertTrue(token.dividendoPagado(id, a));
        assertFalse(token.dividendoPagado(id, b));
    }

    function test_recoveryChainOfTwo() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.startPrank(rec);
        token.recoveryAddress(a, b, "orden");
        token.recoveryAddress(b, c, "orden");
        vm.stopPrank();
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(c), 1100);
        assertEq(token.balanceOf(b), 0);
    }

    // Recupera a hacia una cadena de `saltos` cuentas nuevas; devuelve [a, c1, ..., c_saltos].
    function _cadena(uint256 saltos) internal returns (address[] memory cs) {
        cs = new address[](saltos + 1);
        cs[0] = a;
        for (uint256 i; i < saltos; i++) {
            cs[i + 1] = makeAddr(string.concat("cadena", vm.toString(i)));
            _verify(cs[i + 1]);
            vm.prank(rec);
            token.recoveryAddress(cs[i], cs[i + 1], "orden");
        }
    }

    function test_recoveryChainEightHopsPays() public {
        uint256 id = _snapConDividendo(1, 10);
        address ultima = _cadena(8)[8];
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(ultima), 1100);
    }

    function test_recoveryChainNineHopsOmitted() public {
        uint256 id = _snapConDividendo(1, 10);
        address[] memory cs = _cadena(9);
        address alcanzada = cs[8]; // tras 8 saltos, aún recuperada
        address ultima = cs[9];
        vm.expectEmit(true, true, true, true);
        emit Tepuy.DividendoOmitido(id, a, alcanzada, 100);
        _pagar(id, _uno(a));
        assertFalse(token.dividendoPagado(id, a));
        assertEq(token.balanceOf(ultima), 1000);
        assertEq(token.totalSupply(), 1000);
    }

    // Lote mixto: la cadena larga se omite y el tenedor normal cobra.
    function test_longChainDoesNotBlockBatch() public {
        _mint(b, 1000);
        uint256 id = _snapConDividendo(1, 10);
        _cadena(9);
        _pagar(id, _dos(a, b));
        assertFalse(token.dividendoPagado(id, a));
        assertTrue(token.dividendoPagado(id, b));
        assertEq(token.balanceOf(b), 1100);
    }

    function test_onlyEmisorDistribute() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, a, token.EMISOR()));
        vm.prank(a);
        token.distribuirDividendo(id, _uno(a));
    }

    function test_hugeNumeratorRevertsCleanly() public {
        _mint(a, 1000);
        uint256 id = _snap();
        _declarar(id, type(uint256).max, 1);
        vm.expectRevert();
        _pagar(id, _uno(a));
        assertFalse(token.dividendoPagado(id, a));
        assertEq(token.totalSupply(), 1000);
    }

    function test_omittedRetryEmitsAgainAndFractionOnlyWhenPaid() public {
        _mint(a, 15);
        uint256 id = _snap();
        _declarar(id, 1, 10);
        vm.prank(kyc);
        token.setVerified(a, false);
        vm.recordLogs();
        _pagar(id, _uno(a));
        _pagar(id, _uno(a));
        Vm.Log[] memory l = vm.getRecordedLogs();
        assertEq(l.length, 2); // dos DividendoOmitido, sin FraccionPendiente
        _verify(a);
        vm.expectEmit(true, true, true, true);
        emit Tepuy.FraccionPendiente(id, a, a, 5);
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(a), 16);
    }

    function test_frozenDestinationOmittedThenPayable() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.prank(sup);
        token.setAddressFrozen(a, true);
        vm.expectEmit(true, true, true, true);
        emit Tepuy.DividendoOmitido(id, a, a, 100);
        _pagar(id, _uno(a));
        assertFalse(token.dividendoPagado(id, a));
        assertEq(token.totalSupply(), 1000);
        vm.prank(sup);
        token.setAddressFrozen(a, false);
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(a), 1100);
    }

    function test_unverifiedDestinationOmittedAndBatchContinues() public {
        _mint(a, 1000);
        _mint(b, 1000);
        uint256 id = _snap();
        _declarar(id, 1, 10);
        vm.prank(kyc);
        token.setVerified(a, false);
        _pagar(id, _dos(a, b));
        assertFalse(token.dividendoPagado(id, a));
        assertTrue(token.dividendoPagado(id, b));
        assertEq(token.balanceOf(b), 1100);
        _verify(a);
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(a), 1100);
    }

    function test_recoveredToFrozenNewOmitted() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.prank(rec);
        token.recoveryAddress(a, b, "orden");
        vm.prank(sup);
        token.setAddressFrozen(b, true);
        vm.expectEmit(true, true, true, true);
        emit Tepuy.DividendoOmitido(id, a, b, 100);
        _pagar(id, _uno(a));
        assertFalse(token.dividendoPagado(id, a));
    }

    function test_capInsufficientRevertsWholeBatch() public {
        _mint(a, 1000);
        _mint(b, 1000);
        uint256 id = _snap();
        _declarar(id, 1, 1);
        vm.prank(cust);
        token.setAttestedShares(3500); // alcanza para a (1000) pero no para ambos
        vm.expectRevert(abi.encodeWithSelector(Tepuy.TopeExcedido.selector, 1000, 500));
        _pagar(id, _dos(a, b));
        assertFalse(token.dividendoPagado(id, a));
        assertEq(token.totalSupply(), 2000);
    }

    function test_pausedReverts() public {
        uint256 id = _snapConDividendo(1, 10);
        vm.prank(sup);
        token.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _pagar(id, _uno(a));
        assertFalse(token.dividendoPagado(id, a));
    }

    function test_totalMintedMatchesExpected() public {
        _mint(a, 1000);
        _mint(b, 333);
        _mint(c, 7);
        uint256 id = _snap();
        _declarar(id, 3, 7);
        address[] memory ts = new address[](3);
        ts[0] = a;
        ts[1] = b;
        ts[2] = c;
        _pagar(id, ts);
        // floor(3000/7)=428, floor(999/7)=142, floor(21/7)=3
        assertEq(token.totalSupply(), 1340 + 428 + 142 + 3);
    }

    function testFuzz_amountAndRemainder(uint128 saldo, uint64 n, uint64 d) public {
        n = uint64(bound(n, 1, type(uint64).max));
        d = uint64(bound(d, 1, type(uint64).max));
        vm.prank(cust);
        token.setAttestedShares(type(uint208).max);
        _mint(a, saldo);
        uint256 id = _snap();
        _declarar(id, n, d);
        uint256 monto = uint256(saldo) * n / d;
        uint256 resto = uint256(saldo) * n % d;
        vm.recordLogs();
        _pagar(id, _uno(a));
        assertEq(token.balanceOf(a), uint256(saldo) + monto);
        assertEq(token.totalSupply(), uint256(saldo) + monto);
        assertEq(vm.getRecordedLogs().length, (monto > 0 ? 2 : 0) + (resto > 0 ? 1 : 0));
        assertTrue(token.dividendoPagado(id, a));
    }
}

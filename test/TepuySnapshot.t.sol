// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Tepuy} from "../contracts/Tepuy.sol";

// Pruebas de S9 (snapshots) en archivo aparte: Tepuy.t.sol ya es demasiado grande para el compilador.
contract TepuySnapshotTest is Test {
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
        vm.startPrank(kyc);
        token.setVerified(a, true);
        token.setVerified(b, true);
        token.setVerified(c, true);
        vm.stopPrank();
        vm.prank(cust);
        token.setAttestedShares(1_000_000);
    }

    function _mint(address to, uint256 n) internal {
        vm.prank(emi);
        token.mint(to, n);
    }

    function _snap() internal returns (uint256) {
        vm.prank(emi);
        return token.snapshot();
    }

    function _next() internal {
        vm.roll(block.number + 1);
    }

    function test_onlyEmisor() public {
        bytes32 r = token.EMISOR();
        address[4] memory otros = [admin, sup, a, address(this)];
        for (uint256 i; i < 4; i++) {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, otros[i], r));
            vm.prank(otros[i]);
            token.snapshot();
        }
    }

    function test_sequentialIdsAndEvent() public {
        assertEq(token.snapshotCount(), 0);
        vm.expectEmit(true, true, false, true);
        emit Tepuy.SnapshotCreado(1, uint48(block.number - 1), emi);
        assertEq(_snap(), 1);
        uint256 b1 = block.number;
        _next();
        assertEq(_snap(), 2);
        assertEq(token.snapshotCount(), 2);
        assertEq(token.snapshotBlock(1), b1 - 1);
        assertEq(token.snapshotBlock(2), b1);
    }

    function test_nonexistentReverts() public {
        _snap();
        uint256[3] memory ids = [uint256(0), 2, type(uint256).max];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(abi.encodeWithSelector(Tepuy.SnapshotInexistente.selector, ids[i]));
            token.balanceOfAt(a, ids[i]);
            vm.expectRevert(abi.encodeWithSelector(Tepuy.SnapshotInexistente.selector, ids[i]));
            token.totalSupplyAt(ids[i]);
            vm.expectRevert(abi.encodeWithSelector(Tepuy.SnapshotInexistente.selector, ids[i]));
            token.snapshotBlock(ids[i]);
        }
    }

    function test_valuesFrozenAfterLaterMoves() public {
        _mint(a, 100);
        _next();
        uint256 id = _snap();
        // Transferencia, emisión, forzada y recuperación posteriores no alteran el corte.
        vm.prank(a);
        token.transfer(b, 30);
        _mint(c, 50);
        vm.prank(rec);
        token.forcedTransfer(a, c, 10, "orden");
        vm.prank(rec);
        token.recoveryAddress(b, c, "orden");
        assertEq(token.balanceOf(a), 60);
        assertEq(token.balanceOfAt(a, id), 100);
        assertEq(token.balanceOfAt(b, id), 0);
        assertEq(token.balanceOfAt(c, id), 0);
        assertEq(token.totalSupplyAt(id), 100);
        // Un segundo corte ve el estado nuevo y el primero no cambia.
        _next();
        uint256 id2 = _snap();
        vm.prank(rec);
        token.forcedTransfer(c, a, 5, "orden");
        assertEq(token.balanceOfAt(a, id2), 60);
        assertEq(token.balanceOfAt(b, id2), 0);
        assertEq(token.balanceOfAt(c, id2), 90);
        assertEq(token.totalSupplyAt(id2), 150);
        assertEq(token.balanceOfAt(a, id), 100);
        assertEq(token.totalSupplyAt(id), 100);
    }

    // Movimientos en el mismo bloque del snapshot (antes y despues) no cuentan: el corte es el bloque anterior.
    function test_sameBlockDoesNotChangeCut() public {
        _mint(a, 100);
        _next();
        uint256 id = _snap();
        vm.prank(a);
        token.transfer(b, 40);
        _mint(c, 7);
        vm.prank(rec);
        token.forcedTransfer(a, c, 10, "orden");
        vm.prank(rec);
        token.recoveryAddress(b, c, "orden");
        assertEq(token.balanceOfAt(a, id), 100);
        assertEq(token.balanceOfAt(b, id), 0);
        assertEq(token.balanceOfAt(c, id), 0);
        assertEq(token.totalSupplyAt(id), 100);
        // Lo hecho en el mismo bloque ANTES de snapshot() tampoco entra.
        _next();
        _mint(a, 5);
        uint256 id2 = _snap();
        assertEq(token.balanceOfAt(a, id2), 50);
        assertEq(token.totalSupplyAt(id2), 107);
    }

    function test_zeroTransferKeepsCut() public {
        _mint(a, 100);
        _next();
        uint256 id = _snap();
        _next();
        vm.prank(a);
        token.transfer(b, 0);
        vm.prank(b);
        token.transfer(a, 0);
        assertEq(token.balanceOfAt(a, id), 100);
        assertEq(token.balanceOfAt(b, id), 0);
        assertEq(token.totalSupplyAt(id), 100);
    }

    function test_attestTooLargeReverts() public {
        uint256 n = uint256(type(uint208).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(Tepuy.AtestiguacionExcesiva.selector, n));
        vm.prank(cust);
        token.setAttestedShares(n);
        vm.prank(cust);
        token.setAttestedShares(type(uint208).max);
    }

    function test_worksPausedAndSelfTransfer() public {
        _mint(a, 10);
        _next();
        vm.prank(sup);
        token.pause();
        uint256 id = _snap();
        assertEq(token.balanceOfAt(a, id), 10);
        vm.prank(sup);
        token.unpause();
        _next();
        vm.prank(a);
        token.transfer(a, 4);
        assertEq(token.balanceOf(a), 10);
        assertEq(token.balanceOfAt(a, id), 10);
    }

    function test_beforeFirstCheckpointIsZero() public {
        uint256 id = _snap();
        assertEq(token.balanceOfAt(a, id), 0);
        assertEq(token.totalSupplyAt(id), 0);
    }

    // Secuencias aleatorias de transferencias y cortes: cada corte coincide con un espejo guardado al crearlo.
    function testFuzz_snapshotsMatchMirror(uint256[24] calldata seeds) public {
        address[3] memory xs = [a, b, c];
        _mint(a, 1000);
        _next();
        uint256[3][6] memory espejo;
        uint256[3] memory ciclo = [uint256(1000), 0, 0]; // saldos al cierre del bloque anterior
        uint256 n;
        for (uint256 i; i < 24; i++) {
            uint256 s = seeds[i];
            if (s % 3 != 0) { // a veces mueve en el mismo bloque que el corte
                _next();
                for (uint256 k; k < 3; k++) ciclo[k] = token.balanceOf(xs[k]);
            }
            if (s % 5 == 0 && n < 6) {
                _snap();
                for (uint256 k; k < 3; k++) espejo[n][k] = ciclo[k];
                n++;
            } else {
                vm.prank(xs[(s >> 8) % 3]);
                try token.transfer(xs[(s >> 16) % 3], (s >> 32) % 400) {} catch {}
            }
        }
        for (uint256 id = 1; id <= n; id++) {
            uint256 suma;
            for (uint256 k; k < 3; k++) {
                assertEq(token.balanceOfAt(xs[k], id), espejo[id - 1][k]);
                suma += espejo[id - 1][k];
            }
            assertEq(token.totalSupplyAt(id), suma);
        }
    }
}

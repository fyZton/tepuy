// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Tepuy} from "../contracts/Tepuy.sol";
import {Fecha} from "./handlers/Fecha.sol";

// Pruebas de S8 (precio on-chain) en archivo aparte: Tepuy.t.sol ya es demasiado grande para el compilador.
contract TepuyPrecioTest is Test {
    Tepuy token;
    address admin = makeAddr("admin");
    address orac = makeAddr("orac");
    address sup = makeAddr("sup");
    bytes32 constant H = keccak256("archivo");
    uint256 constant BASE = 1793188800; // 28/10/2026 12:00 UTC

    function setUp() public {
        vm.warp(BASE);
        token = new Tepuy(1 days, admin);
        bytes32 ro = token.ORACULO();
        bytes32 rs = token.SUPERVISOR();
        vm.startPrank(admin);
        token.grantRole(ro, orac);
        token.grantRole(rs, sup);
        vm.stopPrank();
    }

    function _publicar(uint256 c, uint32 f, bytes32 h) internal {
        vm.prank(orac);
        token.publishPrice(c, f, h);
    }

    function test_publishOnlyOraculo() public {
        bytes32 r = token.ORACULO();
        address[3] memory otros = [admin, sup, address(this)];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, otros[i], r));
            vm.prank(otros[i]);
            token.publishPrice(1, 20261027, H);
        }
    }

    function test_publishStateAndEvent() public {
        vm.warp(1_800_000_000);
        vm.expectEmit(true, true, false, true);
        emit Tepuy.PrecioPublicado(20261027, 1699999, H, orac);
        _publicar(1699999, 20261027, H);
        (uint256 c, bytes32 h, uint32 f, uint64 t) = token.ultimoPrecio();
        assertEq(c, 1699999);
        assertEq(f, 20261027);
        assertEq(h, H);
        assertEq(t, block.timestamp);
    }

    function test_publishRules() public {
        vm.expectRevert(Tepuy.PrecioCero.selector);
        _publicar(0, 20261027, H);
        vm.expectRevert(Tepuy.HashVacio.selector);
        _publicar(1, 20261027, bytes32(0));
        uint32[7] memory malas = [uint32(0), 19691231, 20261300, 20260001, 20260100, 20260132, 100000000];
        for (uint256 i; i < 7; i++) {
            vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaInvalida.selector, malas[i]));
            _publicar(1, malas[i], H);
        }
        _publicar(1, 19700101, H); // límite inferior válido
        _publicar(1, 20261027, H);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaNoCreciente.selector, 20261027, 20261027));
        _publicar(1, 20261027, H);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaNoCreciente.selector, 20261026, 20261027));
        _publicar(1, 20261026, H);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaFutura.selector, 99991231, 20261030));
        _publicar(1, 99991231, H);
    }

    function test_publishWorksPaused() public {
        vm.prank(sup);
        token.pause();
        _publicar(5, 20261027, H);
        (uint256 c,,,) = token.ultimoPrecio();
        assertEq(c, 5);
    }

    function testFuzz_publish(uint256 c, uint32 f, bytes32 h) public {
        uint32 mes = (f / 100) % 100;
        bool ok = c > 0 && c <= type(uint128).max && h != 0 && f >= 19700101 && f <= 20261030 && mes >= 1 && mes <= 12 && f % 100 >= 1 && f % 100 <= 31;
        vm.prank(orac);
        try token.publishPrice(c, f, h) {
            assertTrue(ok);
            (uint256 c2, bytes32 h2, uint32 f2,) = token.ultimoPrecio();
            assertEq(c2, c);
            assertEq(f2, f);
            assertEq(h2, h);
        } catch {
            assertFalse(ok);
        }
    }

    function test_priceCap() public {
        vm.expectRevert(abi.encodeWithSelector(Tepuy.PrecioExcesivo.selector, uint256(type(uint128).max) + 1));
        _publicar(uint256(type(uint128).max) + 1, 20261027, H);
        _publicar(type(uint128).max, 20261027, H);
    }

    // Hoy + 2 días vale; hoy + 3 revierte con la máxima.
    function _frontera(uint256 ts, uint32 maxima, uint32 siguiente) internal {
        vm.warp(ts);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaFutura.selector, siguiente, maxima));
        _publicar(1, siguiente, H);
        _publicar(1, maxima, H);
    }

    function test_futureBoundKnownDates() public {
        _frontera(BASE, 20261030, 20261031); // normal
        _frontera(1793188800 + 3 days, 20261102, 20261103); // fin de mes: 31/10 + 2 = 02/11
        _frontera(1798718400, 20270102, 20270103); // 31/12/2026 12:00: cambio de año
        _frontera(1803816000, 20270302, 20270303); // 28/02/2027 no bisiesto: + 2 = 02/03
        _frontera(1835352000, 20280301, 20280302); // 28/02/2028 (bisiesto): + 2 = 01/03
    }

    function test_futureBoundFechaAnterior() public {
        // El tope es de hoy + 2: el mismo día a las 23:59:59 aún cuenta como hoy.
        vm.warp(1793231999); // 28/10/2026 23:59:59
        _publicar(1, 20261030, H);
        vm.warp(1793232000); // 29/10/2026 00:00:00
        vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaFutura.selector, 20261101, 20261031));
        _publicar(1, 20261101, H);
        _publicar(1, 20261031, H);
    }

    // La conversión del contrato coincide con una referencia ingenua en [1970, 2100].
    function testFuzz_futureBoundMatchesReference(uint256 ts) public {
        ts = bound(ts, 0, 4102444800);
        vm.warp(ts);
        uint32 max = Fecha.de(ts + 2 days);
        uint32 sig = Fecha.de(ts + 3 days);
        vm.expectRevert(abi.encodeWithSelector(Tepuy.FechaFutura.selector, sig, max));
        _publicar(1, sig, H);
        if (max >= 19700101) _publicar(1, max, H);
    }
}

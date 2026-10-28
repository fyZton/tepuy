// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tepuy} from "../contracts/Tepuy.sol";
import {TepuyHandler} from "./handlers/TepuyHandler.sol";

contract TepuyInvariantes is Test {
    Tepuy token;
    TepuyHandler handler;

    function setUp() public {
        address admin = makeAddr("admin");
        address emisor = makeAddr("emisor");
        address agente = makeAddr("agente");
        token = new Tepuy(1 days, admin);
        bytes32 r1 = token.EMISOR();
        bytes32 r2 = token.AGENTE_KYC();
        vm.startPrank(admin);
        token.grantRole(r1, emisor);
        token.grantRole(r2, agente);
        vm.stopPrank();
        handler = new TepuyHandler(token, emisor, agente);
        // Arranque con dos verificados para que haya operaciones exitosas.
        vm.startPrank(agente);
        token.setVerified(handler.actores(0), true);
        token.setVerified(handler.actores(1), true);
        vm.stopPrank();
        targetContract(address(handler));
    }

    /// Ninguna llamada exitosa tuvo emisor o receptor sin KYC al momento de ejecutarse.
    function invariant_noUnverifiedReceives() public view {
        assertEq(handler.violaciones(), 0);
    }

    /// Verdad de base: los saldos suman el suministro y ningún actor con saldo recibió sin KYC.
    function invariant_balancesConsistent() public view {
        assertEq(handler.sumaSaldos(), token.totalSupply());
        for (uint256 i; i < 4; i++) {
            address a = handler.actores(i);
            if (token.balanceOf(a) > 0) assertFalse(handler.recibioSinKyc(a));
        }
    }

    /// No vacuidad: el handler sí logra mint, transfer y transferFrom exitosos (con estado inicial fijo).
    function test_handlerSucceeds() public {
        handler.mint(0, 10);
        handler.transfer(0, 1, 4);
        handler.transferFrom(0, 1, 3);
        assertEq(handler.exitos(), 3);
        assertEq(handler.violaciones(), 0);
        assertEq(handler.sumaSaldos(), token.totalSupply());
        assertEq(token.balanceOf(handler.actores(1)), 7);
    }
}

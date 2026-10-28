// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tepuy} from "../contracts/Tepuy.sol";
import {TepuyHandler} from "./handlers/TepuyHandler.sol";

contract TepuyInvariantes is Test {
    Tepuy token;
    TepuyHandler handler;

    function setUp() public {
        vm.warp(1793188800); // 28/10/2026 12:00 UTC
        address admin = makeAddr("admin");
        address emisor = makeAddr("emisor");
        address agente = makeAddr("agente");
        address supervisor = makeAddr("supervisor");
        address custodio = makeAddr("custodio");
        address recuperador = makeAddr("recuperador");
        address oraculo = makeAddr("oraculo");
        token = new Tepuy(1 days, admin);
        bytes32 r1 = token.EMISOR();
        bytes32 r2 = token.AGENTE_KYC();
        bytes32 r3 = token.SUPERVISOR();
        bytes32 r4 = token.CUSTODIO();
        vm.startPrank(admin);
        token.grantRole(r4, custodio);
        token.grantRole(r1, emisor);
        token.grantRole(r2, agente);
        token.grantRole(r3, supervisor);
        token.grantRole(token.RECUPERADOR(), recuperador);
        token.grantRole(token.ORACULO(), oraculo);
        vm.stopPrank();
        handler = new TepuyHandler(token, emisor, agente, supervisor, custodio, recuperador, oraculo);
        // Arranque con dos verificados para que haya operaciones exitosas.
        vm.startPrank(agente);
        token.setVerified(handler.actores(0), true);
        token.setVerified(handler.actores(1), true);
        vm.stopPrank();
        // Atestiguación inicial para que haya emisiones exitosas.
        vm.prank(custodio);
        token.setAttestedShares(5000);
        targetContract(address(handler));
    }

    /// Ninguna llamada exitosa tuvo emisor o receptor sin KYC o congelado al momento de ejecutarse.
    function invariant_noUnverifiedReceives() public view {
        assertEq(handler.violaciones(), 0);
    }

    /// Mientras está pausado, suministro y saldos son los de la foto al pausar.
    function invariant_pausedFrozenState() public view {
        assertEq(handler.violacionesPausa(), 0);
        if (token.paused() && handler.snapPausa()) {
            assertEq(token.totalSupply(), handler.supplyPausa());
            assertEq(handler.sumaSaldos(), handler.saldosPausa());
        }
    }

    /// Saldo de congeladas solo cambia por forzada/recuperación; las forzadas no tocan el suministro.
    function invariant_forcedRules() public view {
        assertEq(handler.violacionesCongelada(), 0);
        assertEq(handler.violacionesForzada(), 0);
        assertEq(handler.violacionesReceptorCongelado(), 0);
    }

    /// Verdad de base: los saldos suman el suministro y ningún actor con saldo recibió sin KYC.
    function invariant_balancesConsistent() public view {
        assertEq(handler.sumaSaldos(), token.totalSupply());
        for (uint256 i; i < 4; i++) {
            address a = handler.actores(i);
            if (token.balanceOf(a) > 0) assertFalse(handler.recibioSinKyc(a));
        }
    }

    /// Nunca hay más tokens que acciones atestiguadas.
    function invariant_supplyWithinAttested() public view {
        assertLe(token.totalSupply(), token.accionesAtestiguadas());
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

    /// No vacuidad del congelamiento: congelada no opera y descongelar restaura.
    function test_handlerFreezeBlocks() public {
        handler.mint(0, 10);
        handler.setAddressFrozen(0, true);
        handler.transfer(0, 1, 4);
        handler.transfer(1, 0, 4);
        handler.mint(0, 5);
        assertEq(handler.exitos(), 1);
        handler.setAddressFrozen(0, false);
        handler.transfer(0, 1, 4);
        assertEq(handler.exitos(), 2);
        assertEq(handler.violaciones(), 0);
    }

    /// No vacuidad del tope: sin cupo el mint falla; bajar del suministro falla; subir reabre el cupo.
    function test_handlerCapBlocks() public {
        handler.setAttestedShares(0);
        handler.mint(0, 1);
        assertEq(handler.exitos(), 0);
        handler.setAttestedShares(10);
        handler.mint(0, 10);
        assertEq(handler.exitos(), 1);
        handler.setAttestedShares(3); // bajo el suministro: el contrato revierte y el handler lo absorbe
        assertEq(token.accionesAtestiguadas(), 10);
        handler.setAttestedShares(20);
        handler.mint(0, 10);
        assertEq(handler.exitos(), 2);
        assertEq(token.totalSupply(), 20);
    }

    /// No vacuidad de la pausa: pausado nada se mueve, y despausar restaura.
    function test_handlerPauseBlocks() public {
        handler.mint(0, 10);
        handler.pause(0);
        handler.pause(1); // semilla no múltiplo de 8: no hace nada
        handler.mint(0, 5);
        handler.transfer(0, 1, 4);
        handler.transferFrom(0, 1, 3);
        assertEq(handler.exitos(), 1);
        handler.unpause(8);
        handler.transfer(0, 1, 4);
        assertEq(handler.exitos(), 2);
        assertEq(handler.violaciones(), 0);
        assertEq(handler.violacionesPausa(), 0);
    }

    /// No vacuidad de S7: forzada funciona con origen congelado y en pausa, rechaza receptor malo; recuperación migra.
    function test_handlerForcedWorks() public {
        handler.mint(0, 10);
        handler.setAddressFrozen(0, true);
        handler.pause(0);
        handler.forcedTransfer(0, 1, 4); // origen address(0): el contrato la rechaza
        assertEq(handler.forzadas(), 0);
        handler.forcedTransfer(4, 1, 4);
        assertEq(handler.forzadas(), 1);
        assertEq(token.balanceOf(handler.actores(1)), 4);
        handler.forcedTransfer(4, 2, 1); // actor 2 sin KYC: rechazada
        handler.setAddressFrozen(1, true);
        handler.forcedTransfer(4, 1, 1); // receptor congelado: rechazada
        assertEq(handler.forzadas(), 1);
        handler.setAddressFrozen(1, false);
        handler.recoveryAddress(0, 1);
        assertEq(handler.forzadas(), 2);
        assertEq(token.balanceOf(handler.actores(1)), 10);
        assertEq(token.balanceOf(handler.actores(0)), 0);
        assertEq(handler.violaciones() + handler.violacionesForzada() + handler.violacionesCongelada(), 0);
    }

    /// La fecha publicada nunca disminuye y el precio publicado nunca es 0.
    function invariant_priceMonotonic() public view {
        assertEq(handler.violacionesPrecio(), 0);
        (uint256 c,, uint32 f,) = token.ultimoPrecio();
        assertEq(f, handler.fechaMax());
        if (f != 0) assertGt(c, 0);
    }

    /// No vacuidad de S8: publica; igual y anterior se rechazan; precio 0 se rechaza.
    function test_handlerPriceWorks() public {
        handler.publishPrice(1, 2, bytes32(uint256(1))); // avanza un día y publica mañana
        assertEq(handler.publicaciones(), 1);
        handler.publishPrice(1, 0, bytes32(uint256(1))); // igual: rechazada
        handler.publishPrice(1, 1, bytes32(uint256(1))); // anterior: rechazada
        handler.publishPrice(0, 2, bytes32(uint256(1))); // precio 0: rechazada
        handler.publishPrice(1, 3, bytes32(uint256(1))); // hoy + 3: rechazada por el tope a futuro
        assertEq(handler.publicaciones(), 1);
        handler.publishPrice(2, 2, bytes32(uint256(1)));
        assertEq(handler.publicaciones(), 2);
        assertEq(handler.violacionesPrecio(), 0);
    }

    /// Cada corte cerrado conserva suministro y saldos de cuando se creó, y los saldos del corte suman su suministro.
    function invariant_snapshotsImmutable() public view {
        assertEq(handler.violacionesSnapshot(), 0);
        for (uint256 i; i < handler.snapshots(); i++) {
            uint256 id = i + 1;
            assertEq(token.balanceOfAt(address(0), id), 0);
            assertEq(token.balanceOfAt(handler.emisor(), id), 0);
            assertEq(token.balanceOfAt(handler.recuperador(), id), 0);
            uint256 suma;
            for (uint256 k; k < handler.N_ACTORES(); k++) {
                uint256 s = token.balanceOfAt(handler.actores(k), id);
                assertEq(s, handler.snapSaldo(i, k));
                suma += s;
            }
            assertEq(token.totalSupplyAt(id), handler.snapSupply(i));
            assertEq(suma, token.totalSupplyAt(id));
        }
    }

    /// No vacuidad de S9: el corte guarda el estado aunque luego se mueva todo, incluso por la vía forzada.
    function test_handlerSnapshotWorks() public {
        handler.mint(0, 10);
        handler.snapshot(1);
        handler.transfer(0, 1, 4); // mismo bloque que el snapshot
        handler.forcedTransfer(4, 1, 3);
        handler.mint(1, 5);
        assertEq(handler.snapshots(), 1);
        assertEq(token.balanceOfAt(handler.actores(0), 1), 10);
        assertEq(token.balanceOfAt(handler.actores(1), 1), 0);
        assertEq(token.totalSupplyAt(1), 10);
        assertEq(handler.violacionesSnapshot(), 0);
        invariant_snapshotsImmutable();
    }

    /// Un dividendo nunca se paga dos veces: un lote repetido no acuña y lo acuñado no supera la suma de pisos por tenedor.
    function invariant_dividendsNeverPaidTwice() public view {
        assertEq(handler.violacionesDividendo(), 0);
        for (uint256 i; i < handler.dividendos(); i++) {
            uint256 id = handler.divIds(i);
            (uint256 n, uint256 d) = token.dividendo(id);
            uint256 maximo;
            for (uint256 k; k < handler.N_ACTORES(); k++) maximo += token.balanceOfAt(handler.actores(k), id) * n / d;
            assertLe(handler.acunado(id), maximo);
        }
    }

    /// No vacuidad de S10: declara, paga, y el segundo lote no acuña; el tope bloquea sin dejar pagos a medias.
    function test_handlerDividendWorks() public {
        handler.mint(0, 100);
        handler.snapshot(1);
        handler.declararDividendo(0, 0, 0); // snapshot 1, proporción 1:1
        assertEq(handler.dividendos(), 1);
        handler.declararDividendo(0, 1, 1); // el mismo snapshot ya tiene dividendo: el contrato lo rechaza
        assertEq(handler.dividendos(), 1);
        handler.distribuirDividendo(0, 0);
        assertEq(handler.acunado(1), 100);
        assertEq(token.balanceOf(handler.actores(0)), 200);
        assertEq(handler.violacionesDividendo(), 0);
        invariant_dividendsNeverPaidTwice();
    }
}

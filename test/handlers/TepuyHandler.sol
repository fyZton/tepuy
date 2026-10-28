// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Tepuy} from "../../contracts/Tepuy.sol";

contract TepuyHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Tepuy public immutable token;
    address public immutable emisor;
    address public immutable agente;
    address public immutable supervisor;
    address public immutable custodio;
    address public immutable recuperador;
    address[4] public actores;
    address public constant SPENDER = address(0xB000); // nunca verificado: no necesita KYC
    uint256 public exitos;
    uint256 public violaciones; // debe quedar en 0
    uint256 public violacionesPausa; // movimientos normales exitosos en pausa; debe quedar en 0
    uint256 public violacionesCongelada; // un movimiento normal cambió saldo de una congelada; debe quedar en 0
    uint256 public violacionesForzada; // forzada que cambió el suministro o dejó mal a la perdida; debe quedar en 0
    uint256 public violacionesReceptorCongelado; // forzada exitosa a un receptor congelado; debe quedar en 0
    uint256 public forzadas; // forzadas y recuperaciones exitosas
    bool public snapPausa; // hay foto tomada al pausar
    uint256 public supplyPausa;
    uint256 public saldosPausa;
    mapping(address => bool) public recibioSinKyc;

    constructor(Tepuy t, address emisor_, address agente_, address supervisor_, address custodio_, address recuperador_) {
        token = t;
        emisor = emisor_;
        agente = agente_;
        supervisor = supervisor_;
        custodio = custodio_;
        recuperador = recuperador_;
        for (uint160 i; i < 4; i++) actores[i] = address(0xA000 + i);
    }

    function _actor(uint256 i) internal view returns (address) {
        return actores[i % 4];
    }

    // Bien = verificada y no congelada, medido antes de la llamada.
    function _bien(address a) internal view returns (bool) {
        return token.isVerified(a) && !token.isFrozen(a);
    }

    // Suma de saldos de las congeladas: ningún movimiento normal puede cambiarla.
    function _saldoCongeladas() internal view returns (uint256 t) {
        for (uint256 i; i < 4; i++) if (token.isFrozen(actores[i])) t += token.balanceOf(actores[i]);
    }

    function _registrar(address from, bool fromOk, address to, bool toOk, bool pausado, uint256 congeladas) internal {
        exitos++;
        if (_saldoCongeladas() != congeladas) violacionesCongelada++;
        if (pausado) violacionesPausa++;
        if ((from != address(0) && !fromOk) || !toOk) {
            violaciones++;
            recibioSinKyc[to] = true;
        }
    }

    // try/catch: una cuenta recuperada no puede verificarse ni descongelarse.
    function setVerified(uint256 i, bool v) external {
        vm.prank(agente);
        try token.setVerified(_actor(i), v) {} catch {}
    }

    function setAddressFrozen(uint256 i, bool c) external {
        vm.prank(supervisor);
        try token.setAddressFrozen(_actor(i), c) {} catch {}
    }

    // Valores en [0, 3000]: a veces quedan bajo el suministro y el contrato debe rechazarlos.
    function setAttestedShares(uint256 n) external {
        vm.prank(custodio);
        try token.setAttestedShares(n % 3001) {} catch {}
    }

    // Se actúa solo 1 de cada 8 semillas para que casi todas las corridas tengan mercado abierto.
    function pause(uint256 seed) external {
        if (seed % 8 != 0) return;
        vm.prank(supervisor);
        try token.pause() {
            snapPausa = true;
            supplyPausa = token.totalSupply();
            saldosPausa = this.sumaSaldos();
        } catch {}
    }

    function unpause(uint256 seed) external {
        if (seed % 8 != 0) return;
        vm.prank(supervisor);
        try token.unpause() {
            snapPausa = false;
        } catch {}
    }

    function mint(uint256 i, uint256 n) external {
        address a = _actor(i);
        bool ok = _bien(a);
        bool pausado = token.paused();
        uint256 cong = _saldoCongeladas();
        vm.prank(emisor);
        try token.mint(a, n % 1000) { _registrar(address(0), true, a, ok, pausado, cong); } catch {}
    }

    function transfer(uint256 i, uint256 j, uint256 n) external {
        address from = _actor(i);
        address to = _actor(j);
        bool fromOk = _bien(from);
        bool toOk = _bien(to);
        bool pausado = token.paused();
        uint256 cong = _saldoCongeladas();
        vm.prank(from);
        try token.transfer(to, n % 1000) { _registrar(from, fromOk, to, toOk, pausado, cong); } catch {}
    }

    function transferFrom(uint256 i, uint256 j, uint256 n) external {
        address from = _actor(i);
        address to = _actor(j);
        n %= 1000;
        vm.prank(from);
        token.approve(SPENDER, n);
        bool fromOk = _bien(from);
        bool toOk = _bien(to);
        bool pausado = token.paused();
        uint256 cong = _saldoCongeladas();
        vm.prank(SPENDER);
        try token.transferFrom(from, to, n) { _registrar(from, fromOk, to, toOk, pausado, cong); } catch {}
    }

    // 1 de cada 7 semillas intenta origen address(0) (seria una emision sin tope): un exito es violacion.
    function forcedTransfer(uint256 i, uint256 j, uint256 n) external {
        address from = i % 7 == 0 ? address(0) : _actor(i);
        address to = _actor(j);
        n %= 1000;
        bool ok = token.isVerified(to);
        bool frozen = token.isFrozen(to);
        uint256 supply = token.totalSupply();
        uint256 deFrom = token.balanceOf(from);
        uint256 deTo = token.balanceOf(to);
        vm.prank(recuperador);
        try token.forcedTransfer(from, to, n, "orden") {
            _registrarForzado(to, ok, frozen, supply);
            if (from == address(0)) violacionesForzada++;
            else if (token.balanceOf(from) != deFrom - n || token.balanceOf(to) != deTo + n) violacionesForzada++;
        } catch {}
    }

    function recoveryAddress(uint256 i, uint256 j) external {
        address perdida = _actor(i);
        address nueva = _actor(j);
        bool ok = token.isVerified(nueva);
        bool frozen = token.isFrozen(nueva);
        uint256 supply = token.totalSupply();
        uint256 saldo = token.balanceOf(perdida);
        uint256 deNueva = token.balanceOf(nueva);
        vm.prank(recuperador);
        try token.recoveryAddress(perdida, nueva, "orden") {
            _registrarForzado(nueva, ok, frozen, supply);
            if (token.balanceOf(perdida) != 0 || token.balanceOf(nueva) != deNueva + saldo) violacionesForzada++;
            if (!token.isFrozen(perdida) || token.isVerified(perdida) || !token.isRecovered(perdida)) violacionesForzada++;
        } catch {}
    }

    function _registrarForzado(address to, bool ok, bool frozen, uint256 supply) internal {
        forzadas++;
        if (token.totalSupply() != supply) violacionesForzada++;
        if (frozen) violacionesReceptorCongelado++;
        if (!ok) {
            violaciones++;
            recibioSinKyc[to] = true;
        }
    }

    function sumaSaldos() external view returns (uint256 t) {
        for (uint256 i; i < 4; i++) t += token.balanceOf(actores[i]);
    }
}

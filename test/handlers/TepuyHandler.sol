// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Tepuy} from "../../contracts/Tepuy.sol";

contract TepuyHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Tepuy public immutable token;
    address public immutable emisor;
    address public immutable agente;
    address[4] public actores;
    address public constant SPENDER = address(0xB000); // nunca verificado: no necesita KYC
    uint256 public exitos;
    uint256 public violaciones; // debe quedar en 0
    mapping(address => bool) public recibioSinKyc;

    constructor(Tepuy t, address emisor_, address agente_) {
        token = t;
        emisor = emisor_;
        agente = agente_;
        for (uint160 i; i < 4; i++) actores[i] = address(0xA000 + i);
    }

    function _actor(uint256 i) internal view returns (address) {
        return actores[i % 4];
    }

    // Se compara con el estado KYC previo a la llamada, no con el posterior.
    function _registrar(address from, bool fromOk, address to, bool toOk) internal {
        exitos++;
        if ((from != address(0) && !fromOk) || !toOk) {
            violaciones++;
            recibioSinKyc[to] = true;
        }
    }

    function setVerified(uint256 i, bool v) external {
        vm.prank(agente);
        token.setVerified(_actor(i), v);
    }

    function mint(uint256 i, uint256 n) external {
        address a = _actor(i);
        bool ok = token.isVerified(a);
        vm.prank(emisor);
        try token.mint(a, n % 1000) { _registrar(address(0), true, a, ok); } catch {}
    }

    function transfer(uint256 i, uint256 j, uint256 n) external {
        address from = _actor(i);
        address to = _actor(j);
        bool fromOk = token.isVerified(from);
        bool toOk = token.isVerified(to);
        vm.prank(from);
        try token.transfer(to, n % 1000) { _registrar(from, fromOk, to, toOk); } catch {}
    }

    function transferFrom(uint256 i, uint256 j, uint256 n) external {
        address from = _actor(i);
        address to = _actor(j);
        n %= 1000;
        vm.prank(from);
        token.approve(SPENDER, n);
        bool fromOk = token.isVerified(from);
        bool toOk = token.isVerified(to);
        vm.prank(SPENDER);
        try token.transferFrom(from, to, n) { _registrar(from, fromOk, to, toOk); } catch {}
    }

    function sumaSaldos() external view returns (uint256 t) {
        for (uint256 i; i < 4; i++) t += token.balanceOf(actores[i]);
    }
}

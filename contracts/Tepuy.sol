// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title Tepuy Demo (TPUY)
/// @author Luis
/// @notice Demo de portafolio. No es un producto oficial ni está afiliado a la
/// Bolsa de Valores de Caracas, la CVV ni SUNAVAL.
contract Tepuy is ERC20, AccessControlDefaultAdminRules {
    /// @notice Rol autorizado a emitir acciones.
    bytes32 public constant EMISOR = keccak256("EMISOR");

    constructor(uint48 initialDelay, address initialAdmin)
        ERC20("Tepuy Demo", "TPUY")
        AccessControlDefaultAdminRules(initialDelay, initialAdmin)
    {}

    /// @notice Las acciones son indivisibles.
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    /// @notice Emite acciones nuevas; solo EMISOR.
    /// @param to Destinatario.
    /// @param amount Cantidad de acciones.
    function mint(address to, uint256 amount) external onlyRole(EMISOR) {
        _mint(to, amount);
    }
}

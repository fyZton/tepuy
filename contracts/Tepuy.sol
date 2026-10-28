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

    /// @notice Custodio (CVV); sus funciones llegan en S5.
    bytes32 public constant CUSTODIO = keccak256("CUSTODIO");
    /// @notice Verifica identidad de inversionistas (S3).
    bytes32 public constant AGENTE_KYC = keccak256("AGENTE_KYC");
    /// @notice Supervisor (SUNAVAL): pausa (S6).
    bytes32 public constant SUPERVISOR = keccak256("SUPERVISOR");
    /// @notice Publica el precio oficial (S8).
    bytes32 public constant ORACULO = keccak256("ORACULO");
    /// @notice Recupera claves perdidas (S7).
    bytes32 public constant RECUPERADOR = keccak256("RECUPERADOR");

    /// @notice Retraso mínimo del traspaso de admin.
    uint48 public constant RETRASO_MINIMO = 1 hours;

    /// @notice El retraso es menor que RETRASO_MINIMO.
    error RetrasoInsuficiente(uint48 dado, uint48 minimo);

    constructor(uint48 initialDelay, address initialAdmin)
        ERC20("Tepuy Demo", "TPUY")
        AccessControlDefaultAdminRules(initialDelay, initialAdmin)
    {
        _exigirRetraso(initialDelay);
    }

    // Un retraso 0 anularía la protección de AccessControlDefaultAdminRules.
    function _exigirRetraso(uint48 retraso) private pure {
        if (retraso < RETRASO_MINIMO) revert RetrasoInsuficiente(retraso, RETRASO_MINIMO);
    }

    function _changeDefaultAdminDelay(uint48 newDelay) internal override {
        _exigirRetraso(newDelay);
        super._changeDefaultAdminDelay(newDelay);
    }

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

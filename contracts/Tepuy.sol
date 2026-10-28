// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title Tepuy Demo (TPUY)
/// @author Luis
/// @notice Demo de portafolio. No es un producto oficial ni está afiliado a la
/// Bolsa de Valores de Caracas, la CVV ni SUNAVAL.
contract Tepuy is ERC20, Pausable, AccessControlDefaultAdminRules {
    /// @notice Rol autorizado a emitir acciones.
    bytes32 public constant EMISOR = keccak256("EMISOR");

    /// @notice Custodio (CVV): atestigua las acciones que tiene en custodia.
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

    /// @notice La cuenta no está verificada (KYC).
    error NoVerificado(address cuenta);
    /// @notice La dirección cero no puede verificarse.
    error CuentaInvalida();
    /// @notice La cuenta está congelada por el supervisor.
    error CuentaCongelada(address cuenta);

    // Indexar un bool no sirve: se desactiva gas-indexed-events en el evento.
    /// @notice Cambió el estado KYC de una cuenta.
    /// @param cuenta Cuenta afectada.
    /// @param verificado Nuevo estado.
    /// @param agente Quien lo cambió.
    event VerificacionCambiada(address indexed cuenta, bool verificado, address indexed agente); // solhint-disable-line gas-indexed-events

    /// @notice Cambió el congelamiento de una cuenta.
    /// @param cuenta Cuenta afectada.
    /// @param congelada Nuevo estado.
    /// @param supervisor Quien lo cambió.
    event CongelamientoCambiado(address indexed cuenta, bool congelada, address indexed supervisor); // solhint-disable-line gas-indexed-events

    /// @notice Se intentó emitir más que el tope atestiguado.
    error TopeExcedido(uint256 solicitado, uint256 disponible);
    /// @notice La atestiguación nueva es menor que el suministro.
    error AtestiguacionInsuficiente(uint256 nuevas, uint256 suministro);

    /// @notice Cambió la cantidad de acciones atestiguadas.
    /// @param anterior Valor previo.
    /// @param nueva Valor nuevo.
    /// @param custodio Quien lo cambió.
    event AtestiguacionCambiada(uint256 anterior, uint256 nueva, address indexed custodio); // solhint-disable-line gas-indexed-events

    /// @notice Acciones atestiguadas en custodia; tope del suministro. Arranca en 0.
    /// @dev Afirmación del CUSTODIO, no prueba de custodia: el tope es tan honesto como él.
    uint256 public accionesAtestiguadas;

    mapping(address => bool) private _verificados;
    mapping(address => bool) private _congeladas;

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
        // Todo camino futuro de emisión debe pasar por este chequeo del tope.
        // Se valida aquí y no en _update para devolver el cupo disponible; mint es el único origen de emisión.
        // Resta (no suma) para no desbordar con montos enormes: suministro <= atestiguadas siempre.
        uint256 disponible = accionesAtestiguadas - totalSupply();
        if (amount > disponible) revert TopeExcedido(amount, disponible);
        _mint(to, amount);
    }

    /// @notice Fija las acciones atestiguadas; solo CUSTODIO. No puede quedar bajo el suministro.
    /// @dev Confianza: CUSTODIO+EMISOR coludidos pueden sobreemitir; un CUSTODIO malicioso puede bloquear emisión.
    /// @param nuevas Nueva cantidad atestiguada.
    function setAttestedShares(uint256 nuevas) external onlyRole(CUSTODIO) {
        if (nuevas < totalSupply()) revert AtestiguacionInsuficiente(nuevas, totalSupply());
        uint256 anterior = accionesAtestiguadas;
        if (anterior == nuevas) return; // sin cambio: sin escritura ni evento
        accionesAtestiguadas = nuevas;
        emit AtestiguacionCambiada(anterior, nuevas, msg.sender);
    }

    /// @notice Indica si la cuenta pasó KYC (nombre ERC-3643).
    /// @param cuenta Cuenta a consultar.
    /// @return Si está verificada.
    function isVerified(address cuenta) public view returns (bool) {
        return _verificados[cuenta];
    }

    /// @notice Marca o desmarca a una cuenta como verificada; solo AGENTE_KYC. Sin datos personales on-chain.
    /// @param cuenta Cuenta a cambiar.
    /// @param verificado Nuevo estado.
    function setVerified(address cuenta, bool verificado) external onlyRole(AGENTE_KYC) {
        if (cuenta == address(0)) revert CuentaInvalida();
        if (_verificados[cuenta] == verificado) return; // sin cambio: sin escritura ni evento
        _verificados[cuenta] = verificado;
        emit VerificacionCambiada(cuenta, verificado, msg.sender);
    }

    /// @notice Indica si la cuenta está congelada (nombre ERC-3643).
    /// @param cuenta Cuenta a consultar.
    /// @return Si está congelada.
    function isFrozen(address cuenta) public view returns (bool) {
        return _congeladas[cuenta];
    }

    /// @notice Congela o descongela una cuenta; solo SUPERVISOR. Independiente del KYC.
    /// @param cuenta Cuenta a cambiar.
    /// @param congelada Nuevo estado.
    function setAddressFrozen(address cuenta, bool congelada) external onlyRole(SUPERVISOR) {
        if (cuenta == address(0)) revert CuentaInvalida();
        if (_congeladas[cuenta] == congelada) return; // sin cambio: sin escritura ni evento
        _congeladas[cuenta] = congelada;
        emit CongelamientoCambiado(cuenta, congelada, msg.sender);
    }

    /// @notice Pausa transferencias y emisión; solo SUPERVISOR. Revierte si ya está pausado (a diferencia de setVerified/setAddressFrozen, que no hacen nada). KYC, congelamiento y atestiguación siguen activos.
    function pause() external onlyRole(SUPERVISOR) {
        _pause();
    }

    /// @notice Reanuda el mercado; solo SUPERVISOR.
    function unpause() external onlyRole(SUPERVISOR) {
        _unpause();
    }

    // Único punto de reglas. Orden: pausa (la más general), KYC (from, to) y luego congelamiento (from, to).
    // S7 usará un camino interno que salta solo pausa y congelamiento, manteniendo el KYC del receptor.
    // Quemar (to == 0) no exige KYC ni congelamiento del receptor, pero sí del emisor.
    // Quitar KYC a quien tiene saldo lo bloquea hasta que el RECUPERADOR lo mueva (S7).
    // El spender de transferFrom no necesita KYC: solo importan from y to.
    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        if (from != address(0)) _exigirKyc(from);
        if (to != address(0)) _exigirKyc(to);
        if (from != address(0) && _congeladas[from]) revert CuentaCongelada(from);
        if (to != address(0) && _congeladas[to]) revert CuentaCongelada(to);
        _mover(from, to, value);
    }

    function _exigirKyc(address cuenta) private view {
        if (!_verificados[cuenta]) revert NoVerificado(cuenta);
    }

    // Punto de movimiento sin reglas: solo lo llama _update (S7 tendrá su propia vía con KYC del receptor).
    function _mover(address from, address to, uint256 value) private {
        super._update(from, to, value);
    }
}

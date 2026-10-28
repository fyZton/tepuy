// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title Tepuy Demo (TPUY)
/// @author Luis
/// @notice Demo de portafolio. No es un producto oficial ni está afiliado a la
/// Bolsa de Valores de Caracas, la CVV ni SUNAVAL.
contract Tepuy is ERC20, Pausable, AccessControlDefaultAdminRules {
    using Checkpoints for Checkpoints.Trace208;

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

    /// @notice Largo máximo en bytes del motivo de un movimiento forzado.
    uint256 public constant MAX_MOTIVO = 256;

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

    /// @notice El motivo de un movimiento forzado está vacío.
    error MotivoVacio();
    /// @notice El movimiento forzado es de una cuenta a sí misma.
    error CuentasIguales(address cuenta);
    /// @notice El motivo supera MAX_MOTIVO bytes.
    error MotivoLargo(uint256 largo);
    /// @notice La cuenta fue recuperada: no puede verificarse ni descongelarse nunca más.
    error CuentaYaRecuperada(address cuenta);
    /// @notice El monto de un movimiento forzado es cero.
    error MontoCero();
    /// @notice La cuenta a recuperar no tiene saldo.
    error SinSaldo(address cuenta);

    /// @notice El RECUPERADOR movió acciones por orden judicial o regulatoria.
    /// @param from Cuenta de origen.
    /// @param to Cuenta de destino.
    /// @param amount Acciones movidas.
    /// @param motivo Referencia de la orden.
    /// @param recuperador Quien lo ejecutó.
    event TransferenciaForzada(address indexed from, address indexed to, uint256 amount, string motivo, address indexed recuperador); // solhint-disable-line gas-indexed-events

    /// @notice El RECUPERADOR migró el saldo de una clave perdida.
    /// @param perdida Cuenta abandonada.
    /// @param nueva Cuenta que recibe.
    /// @param saldo Acciones migradas.
    /// @param motivo Referencia de la solicitud.
    /// @param recuperador Quien lo ejecutó.
    event CuentaRecuperada(address indexed perdida, address indexed nueva, uint256 saldo, string motivo, address indexed recuperador); // solhint-disable-line gas-indexed-events

    /// @notice Se intentó emitir más que el tope atestiguado.
    error TopeExcedido(uint256 solicitado, uint256 disponible);
    /// @notice La atestiguación supera uint208 (límite de los checkpoints).
    error AtestiguacionExcesiva(uint256 nuevas);
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

    /// @notice La fecha no tiene forma AAAAMMDD válida.
    error FechaInvalida(uint32 fecha);
    /// @notice La fecha no es mayor que la última publicada.
    error FechaNoCreciente(uint32 fecha, uint32 ultima);
    /// @notice La fecha supera hoy + 2 días (por el reloj del bloque).
    error FechaFutura(uint32 fecha, uint32 maxima);
    /// @notice El precio es cero.
    error PrecioCero();
    /// @notice El precio supera uint128.
    error PrecioExcesivo(uint256 centimos);
    /// @notice El SHA-256 del archivo es cero.
    error HashVacio();

    /// @notice El ORACULO publicó el precio de cierre de una fecha.
    /// @param fecha Fecha AAAAMMDD.
    /// @param centimos Precio en céntimos de Bs.
    /// @param sha256Archivo SHA-256 del archivo oficial.
    /// @param oraculo Quien lo publicó.
    event PrecioPublicado(uint32 indexed fecha, uint256 centimos, bytes32 sha256Archivo, address indexed oraculo); // solhint-disable-line gas-indexed-events

    /// @notice Último precio publicado.
    struct Precio {
        uint256 centimos;
        bytes32 sha256Archivo;
        uint32 fecha;
        uint64 publicadoEn;
    }

    /// @notice Último precio de cierre (getter con campos individuales; vacío antes de la primera publicación).
    Precio public ultimoPrecio;

    /// @notice El snapshot no existe (id 0 o aún no creado).
    error SnapshotInexistente(uint256 id);

    /// @notice El EMISOR fijó una fecha de registro.
    /// @param id Id del snapshot (desde 1).
    /// @param bloque Bloque de corte (el anterior al de la transacción).
    /// @param emisor Quien lo creó.
    event SnapshotCreado(uint256 indexed id, uint48 bloque, address indexed emisor); // solhint-disable-line gas-indexed-events

    // Reloj de los checkpoints = número de bloque (monótono y sin depender del timestamp).
    mapping(address => Checkpoints.Trace208) private _saldos;
    Checkpoints.Trace208 private _suministro;
    uint48[] private _bloques; // _bloques[id - 1] = bloque del snapshot id

    mapping(address => bool) private _verificados;
    mapping(address => bool) private _congeladas;
    mapping(address => bool) private _recuperadas;

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
        if (nuevas > type(uint208).max) revert AtestiguacionExcesiva(nuevas);
        if (nuevas < totalSupply()) revert AtestiguacionInsuficiente(nuevas, totalSupply());
        uint256 anterior = accionesAtestiguadas;
        if (anterior == nuevas) return; // sin cambio: sin escritura ni evento
        accionesAtestiguadas = nuevas;
        emit AtestiguacionCambiada(anterior, nuevas, msg.sender);
    }

    /// @notice Publica el precio de cierre diario; solo ORACULO. Funciona aunque el mercado esté pausado.
    /// @dev El hash es un compromiso público verificable contra el archivo oficial, no prueba de que el precio sea correcto. Valida solo la forma de la fecha, no el calendario.
    /// @param centimos Precio en céntimos de Bs (> 0 y <= uint128 max).
    /// @param fecha Fecha AAAAMMDD, mayor que la última y como máximo hoy + 2 días.
    /// @param sha256Archivo SHA-256 del archivo oficial (no cero).
    function publishPrice(uint256 centimos, uint32 fecha, bytes32 sha256Archivo) external onlyRole(ORACULO) {
        if (centimos == 0) revert PrecioCero();
        if (centimos > type(uint128).max) revert PrecioExcesivo(centimos);
        if (sha256Archivo == bytes32(0)) revert HashVacio();
        uint32 mes = (fecha / 100) % 100;
        uint32 dia = fecha % 100;
        if (fecha < 19700101 || fecha > 99991231 || mes < 1 || mes > 12 || dia < 1 || dia > 31) revert FechaInvalida(fecha);
        // Sin tope a futuro una fecha lejana bloquearía al oráculo para siempre (sin función de reinicio).
        uint32 maxima = _aaaammdd(block.timestamp + 2 days);
        // slither-disable-next-line timestamp
        if (fecha > maxima) revert FechaFutura(fecha, maxima);
        uint32 ultima = ultimoPrecio.fecha;
        if (fecha <= ultima) revert FechaNoCreciente(fecha, ultima); // solhint-disable-line gas-strict-inequalities
        ultimoPrecio = Precio(centimos, sha256Archivo, fecha, uint64(block.timestamp));
        emit PrecioPublicado(fecha, centimos, sha256Archivo, msg.sender);
    }

    // Fecha civil (UTC) AAAAMMDD de un timestamp; algoritmo civil-from-days de Howard Hinnant.
    // slither-disable-start divide-before-multiply,timestamp
    function _aaaammdd(uint256 ts) private pure returns (uint32) {
        uint256 z = ts / 1 days + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 dia = doy - (153 * mp + 2) / 5 + 1;
        uint256 mes = mp < 10 ? mp + 3 : mp - 9;
        uint256 anio = yoe + era * 400 + (mes < 3 ? 1 : 0);
        return uint32(anio * 10000 + mes * 100 + dia);
    }
    // slither-disable-end divide-before-multiply,timestamp

    /// @notice Fija una fecha de registro; solo EMISOR (decide él la fecha). Funciona en pausa.
    /// @dev El corte es el bloque ANTERIOR (block.number - 1): ya está cerrado, así que es definitivo al crearse y nada del bloque actual lo altera. En Arbitrum block.number es el del L1. Movimientos del mismo bloque, antes o después de snapshot(), no cuentan.
    /// @return id Id del snapshot (empieza en 1).
    function snapshot() external onlyRole(EMISOR) returns (uint256 id) {
        uint48 corte = uint48(block.number - 1);
        _bloques.push(corte);
        id = _bloques.length;
        emit SnapshotCreado(id, corte, msg.sender);
    }

    /// @notice Saldo de una cuenta al final del bloque de corte del snapshot.
    /// @param cuenta Cuenta a consultar.
    /// @param id Id del snapshot.
    /// @return Saldo en ese corte.
    function balanceOfAt(address cuenta, uint256 id) external view returns (uint256) {
        return _saldos[cuenta].upperLookup(_bloque(id));
    }

    /// @notice Suministro total al final del bloque de corte del snapshot.
    /// @param id Id del snapshot.
    /// @return Suministro en ese corte.
    function totalSupplyAt(uint256 id) external view returns (uint256) {
        return _suministro.upperLookup(_bloque(id));
    }

    /// @notice Cantidad de snapshots creados (el último id).
    /// @return Total de snapshots.
    function snapshotCount() external view returns (uint256) {
        return _bloques.length;
    }

    /// @notice Bloque de corte de un snapshot (último bloque incluido).
    /// @param id Id del snapshot.
    /// @return Número de bloque.
    function snapshotBlock(uint256 id) external view returns (uint48) {
        return _bloque(id);
    }

    function _bloque(uint256 id) private view returns (uint48) {
        if (id == 0 || id > _bloques.length) revert SnapshotInexistente(id);
        return _bloques[id - 1];
    }

    /// @notice Indica si la cuenta pasó KYC (nombre ERC-3643).
    /// @param cuenta Cuenta a consultar.
    /// @return Si está verificada.
    function isVerified(address cuenta) public view returns (bool) {
        return _verificados[cuenta];
    }

    /// @notice Indica si la cuenta fue recuperada (irreversible).
    /// @param cuenta Cuenta a consultar.
    /// @return Si fue recuperada.
    function isRecovered(address cuenta) public view returns (bool) {
        return _recuperadas[cuenta];
    }

    /// @notice Marca o desmarca a una cuenta como verificada; solo AGENTE_KYC. Sin datos personales on-chain.
    /// @param cuenta Cuenta a cambiar.
    /// @param verificado Nuevo estado.
    function setVerified(address cuenta, bool verificado) external onlyRole(AGENTE_KYC) {
        if (cuenta == address(0)) revert CuentaInvalida();
        if (verificado && _recuperadas[cuenta]) revert CuentaYaRecuperada(cuenta);
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
        if (!congelada && _recuperadas[cuenta]) revert CuentaYaRecuperada(cuenta);
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

    /// @notice Mueve acciones por orden judicial; solo RECUPERADOR. Salta pausa y congelamiento del origen; el receptor debe estar verificado y no congelado.
    /// @param from Origen (puede estar sin KYC, congelado o en pausa).
    /// @param to Destino verificado y no congelado.
    /// @param amount Acciones a mover (> 0).
    /// @param motivo Referencia de la orden (no vacío).
    /// @return Siempre true.
    function forcedTransfer(address from, address to, uint256 amount, string calldata motivo)
        external
        onlyRole(RECUPERADOR)
        returns (bool)
    {
        _forzar(from, to, amount, motivo);
        emit TransferenciaForzada(from, to, amount, motivo, msg.sender);
        return true;
    }

    /// @notice Migra todo el saldo de una clave perdida a una cuenta ya verificada; solo RECUPERADOR.
    /// @dev Congela y desverifica la cuenta perdida, sin vuelta atrás: si la clave reaparece no puede recibir ni mover nada (sí se le puede rescatar saldo con forcedTransfer).
    /// @param perdida Cuenta abandonada.
    /// @param nueva Cuenta verificada por AGENTE_KYC y no congelada.
    /// @param motivo Referencia de la solicitud (no vacío).
    /// @return Siempre true.
    function recoveryAddress(address perdida, address nueva, string calldata motivo)
        external
        onlyRole(RECUPERADOR)
        returns (bool)
    {
        uint256 saldo = balanceOf(perdida);
        if (saldo == 0) revert SinSaldo(perdida);
        _forzar(perdida, nueva, saldo, motivo);
        // Irreversible: los permisos (approve) de la clave perdida quedan inertes porque nunca puede reactivarse.
        _recuperadas[perdida] = true;
        if (!_congeladas[perdida]) {
            _congeladas[perdida] = true;
            emit CongelamientoCambiado(perdida, true, msg.sender);
        }
        if (_verificados[perdida]) {
            _verificados[perdida] = false;
            emit VerificacionCambiada(perdida, false, msg.sender);
        }
        emit CuentaRecuperada(perdida, nueva, saldo, motivo, msg.sender);
        return true;
    }

    // Vía interna: salta solo pausa y congelamiento del origen. address(0) como origen sería una emisión sin tope.
    function _forzar(address from, address to, uint256 amount, string calldata motivo) private {
        if (bytes(motivo).length == 0) revert MotivoVacio();
        if (bytes(motivo).length > MAX_MOTIVO) revert MotivoLargo(bytes(motivo).length);
        if (from == address(0) || to == address(0)) revert CuentaInvalida();
        if (from == to) revert CuentasIguales(from);
        if (amount == 0) revert MontoCero();
        _exigirKyc(to);
        if (_congeladas[to]) revert CuentaCongelada(to);
        _mover(from, to, amount);
    }

    // Único punto de reglas. Orden: pausa (la más general), KYC (from, to) y luego congelamiento (from, to).
    // S7 (_forzar) salta solo pausa y congelamiento, manteniendo el KYC y congelamiento del receptor.
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

    // Punto de movimiento sin reglas: solo lo llaman _update y _forzar (que valida el receptor).
    // Aquí se escriben los checkpoints: ningún camino (normal, mint, forzado) los salta.
    function _mover(address from, address to, uint256 value) private {
        super._update(from, to, value);
        uint48 b = uint48(block.number); // el tope uint208 de la atestiguación evita el revert; SafeCast es defensa en profundidad
        // slither-disable-start unused-return
        if (from == address(0) || to == address(0)) _suministro.push(b, SafeCast.toUint208(totalSupply()));
        if (from != address(0)) _saldos[from].push(b, SafeCast.toUint208(balanceOf(from)));
        if (to != address(0)) _saldos[to].push(b, SafeCast.toUint208(balanceOf(to)));
        // slither-disable-end unused-return
    }
}

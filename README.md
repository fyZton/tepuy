# Tepuy

**Aviso:** Tepuy es un prototipo de demostración que corre en una red local y en redes de prueba (testnet). No es una oferta de valores, no capta dinero y no está afiliado a la Bolsa de Valores de Caracas (BVC), la Caja Venezolana de Valores (CVV) ni SUNAVAL. Los tokens no tienen valor. MVZ.A se usa solo como ejemplo con datos públicos de cierre; su emisor no participa en este proyecto.

## Qué es

Un token (TPUY) que representa 1 acción de una empresa listada en la BVC, con un tope igual a las acciones que el custodio dice guardar.
Solo cuentas verificadas (KYC) pueden tenerlo, y un supervisor puede congelar cuentas o pausar el mercado.
El precio de cierre diario se publica en la cadena junto con la huella SHA-256 del archivo oficial de la BVC, para que cualquiera lo compare.

## El problema

- Ninguna acción listada en la BVC se ha tokenizado de forma pública.
- La BDVE (Bolsa Digital de Valores de Venezuela) fue aprobada por SUNAVAL en 2020 y está inactiva desde 2023.
- Un token que representa una acción es un valor: lo regula SUNAVAL bajo la Ley de Mercado de Valores. No basta con emitir un token; hacen falta custodia, identificación de inversionistas y supervisión.

José Grasso Vecchio, presidente de la BVC, lo resume así: "activo verificable, primero; estructura robusta de cumplimiento, segundo; y la tecnología como herramienta de eficiencia, tercero" ([fuente](https://www.diariobitcoin.com/empresas/informe-de-bitfinex-securities-plantea-que-la-tokenizacion-podria-impulsar-reconstruccion-economica-de-venezuela/)).

## Cómo lo resuelve Tepuy

Tepuy sigue ese mismo orden.

1. Activo verificable
   - El rol CUSTODIO (la CVV en la vida real) atestigua cuántas acciones guarda. El contrato no deja emitir más tokens que ese número (`totalSupply <= atestiguado`) y el custodio no puede bajar la cifra por debajo de lo ya emitido.
   - El rol ORACULO publica el cierre diario en céntimos de bolívar, la fecha y el SHA-256 del archivo diario de la BVC. Cualquiera puede descargar ese archivo, calcular su hash y compararlo.
   - Límite honesto: la atestiguación es una afirmación del custodio, no una prueba de custodia, y el hash prueba qué archivo se usó, no que el precio sea correcto.
2. Cumplimiento
   - KYC en ambos lados de cada movimiento: quien envía y quien recibe deben estar verificados.
   - El SUPERVISOR (SUNAVAL en la vida real) congela cuentas y pausa transferencias y emisión.
   - El RECUPERADOR hace transferencias forzadas y recupera cuentas de claves perdidas, siempre con un motivo escrito en el evento. El receptor debe tener KYC.
   - Cada función la tiene un rol distinto y la cuenta que despliega el contrato se queda sin roles.
   - No hay datos personales en la cadena: solo direcciones y si están verificadas.
3. Tecnología
   - Contrato en Solidity sobre OpenZeppelin 5.6.1, inmutable (sin proxy), con nombres de funciones al estilo ERC-3643 (`isVerified`, `setAddressFrozen`, `forcedTransfer`, `recoveryAddress`, `pause`). Inspirado en ERC-3643, no certificado.
   - Fecha de registro (snapshots) y dividendo en acciones.
   - Oráculo y monitor en Python; web estática que solo lee la cadena.

## Véalo en 1 minuto

Requiere Node.js y los puertos 8545 y 3000 libres.

```bash
npm install
npm run demo
```

`npm run demo` levanta un nodo local, despliega el contrato, sirve la web y arranca un simulador con inversionistas ficticios que operan entre sí. Ctrl+C apaga todo.

Abra http://127.0.0.1:3000 y pulse **Probar con alguien sin KYC**: el contrato rechaza pasarle una acción a una persona sin verificar y la página explica por qué. La simulación no envía nada ni cambia saldos.

## Cómo verificar el precio

Al desplegar, el contrato recibe el cierre de MVZ.A del archivo diario de la BVC del 27/10/2026, guardado byte a byte en `oraculo/tests/fixtures/20261027.dat`.

1. Calcule el hash del archivo:

   ```bash
   sha256sum oraculo/tests/fixtures/20261027.dat
   # 972a85a50f005b54db7edaa08d4ad49fd5c416f2a1dccd70a1cd1ee5b689c1b3
   ```

   En PowerShell: `Get-FileHash oraculo/tests/fixtures/20261027.dat -Algorithm SHA256`.
2. Compárelo con "SHA-256 del archivo" en la sección "Precio de referencia (BVC)" de la página.
3. Lea el cierre con el parser:

   ```bash
   python -m oraculo.parser oraculo/tests/fixtures/20261027.dat MVZ.A
   # {"ticker": "MVZ.A", "centimos": 1699999, "fecha": 20261027, "sha256": "972a85a5..."}
   ```

Con un archivo de otra fecha el proceso es el mismo: descargue el archivo diario de la BVC de esa fecha, sin abrirlo ni guardarlo con otro programa (cualquier cambio de un byte cambia el hash), y compare.

Ojo: en `npm run demo` el simulador publica precios inventados cada cierto tiempo, con hashes de texto de prueba, que no corresponden a ningún archivo. Para ver solo el precio real, levante las partes por separado sin simulador: `npm run node`, luego `npm run deploy:local` y `npm run web` en otras terminales.

## Arquitectura

```
 archivo diario BVC (.dat)
          |
          v
 oraculo/publicador.py  --publishPrice-->  contracts/Tepuy.sol  <--lee--  web/ (ethers v6, solo lectura)
 (parser + SHA-256)                        (roles, KYC, tope,             http://127.0.0.1:3000
                                            pausa, snapshots)
                                                  |
                                               eventos
                                                  v
                                          oraculo/monitor.py --> Telegram
```

- `contracts/Tepuy.sol`: el token. Todas las reglas (pausa, KYC, congelamiento) pasan por un solo punto, `_update`.
- `oraculo/parser.py`: lee el `.dat`, devuelve el cierre en céntimos y el SHA-256.
- `oraculo/publicador.py`: publica el cierre. `--dry-run` muestra qué haría sin enviar. En red pública exige `CONFIRM_DEPLOY=yes` y `TEPUY_ORACULO_KEY`.
- `oraculo/monitor.py`: vigila eventos (pausa, transferencia forzada, recuperación, cambios de rol, congelamientos, KYC revocado) y avisa por Telegram (`TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`). `--dry-run` imprime en vez de enviar.
- `web/`: tablero de solo lectura, feed de operaciones en vivo y simulador de transferencias.

## Roles

| Rol | Qué puede hacer |
|-----|-----------------|
| DEFAULT_ADMIN | Otorga y quita roles. Su propio traspaso tiene espera (24 h en el despliegue). |
| EMISOR | Emite hasta el tope, crea fechas de registro y paga dividendos en acciones. |
| CUSTODIO | Atestigua cuántas acciones guarda (la CVV en la vida real). |
| AGENTE_KYC | Verifica o desverifica inversionistas. |
| SUPERVISOR | Congela cuentas, pausa y reanuda el mercado (SUNAVAL en la vida real). |
| ORACULO | Publica el cierre diario con el SHA-256 del archivo. |
| RECUPERADOR | Transferencia forzada y recuperación de cuentas, con motivo (con orden judicial en la vida real). |

Qué puede hacer cada rol si roban su clave: [docs/SECURITY.md](docs/SECURITY.md).

## Pruebas

| Qué | Comando | Resultado |
|-----|---------|-----------|
| Contrato (unitarias, fuzz, invariantes) | `npm test` | 148 pasan |
| Lint + pruebas + despliegue + Slither | `npm run check` | falla si algo falla |
| Oráculo y monitor | `python -m pytest oraculo -q` | 95 pasan, 1 omitida |
| Navegador (Playwright) | `npm run e2e` | 17 pruebas en 3 archivos |

Para Python: `python -m venv .venv` y `pip install -r requirements.txt`.

## Seguridad

- Slither: 0 resultados. solhint: 0. Cobertura de `Tepuy.sol`: 100 % de líneas y ramas.
- 9 invariantes con 256 corridas de profundidad 64 (suministro dentro del tope, nadie sin KYC recibe, snapshots inmutables, un dividendo no se paga dos veces, entre otras).
- Modelo de amenazas por rol y límites conocidos: [docs/SECURITY.md](docs/SECURITY.md). Decisiones de diseño: [docs/SDD.md](docs/SDD.md).

**Es un prototipo sin auditoría externa.** No lo use con fondos ni datos reales. El DEFAULT_ADMIN puede otorgarse cualquier rol; CUSTODIO y EMISOR coludidos pueden emitir sin respaldo; el RECUPERADOR puede mover cualquier saldo hacia una cuenta verificada.

## Despliegue

Los pasos para Arbitrum Sepolia (testnet) están en [docs/DESPLIEGUE.md](docs/DESPLIEGUE.md). Sin `CONFIRM_DEPLOY=yes` el script solo imprime el plan y no envía nada.

Todavía no hay nada desplegado en ninguna red pública.

## Camino a producción

Lo que necesitaría un emisor real, además de este código:

- Aprobación regulatoria de SUNAVAL para emitir y negociar el token como valor.
- Integración con la CVV: conciliación diaria entre la atestiguación y su registro.
- Multifirma por institución para cada rol, timelock para el admin y admins de rol separados.
- Proceso legal para la recuperación y la transferencia forzada (orden judicial, propuesta y ejecución con retraso).
- Privacidad: los datos de KYC quedan fuera de la cadena; en la cadena solo direcciones. Aun así, la lista de verificados es pública y puede correlacionarse con identidades.
- Filtro de sanciones (OFAC, incluida la EO 13884 sobre Venezuela) antes de verificar a alguien.
- Auditoría externa del contrato.
- Oráculo con varios firmantes y ventana de disputa antes de que un precio valga.
- Dividendos en efectivo (por ejemplo en USDT) y splits inversos: no están implementados; solo existe el dividendo en acciones. El contrato no tiene función de quemar y es inmutable, así que un split inverso exigiría un contrato nuevo.
- Alternativa: emitir en Liquid con Blockstream AMP, como hace Bitfinex Securities. Es la fase 2 y no está construida.

## Estado

Prototipo local funcionando: contrato, oráculo, monitor, web y simulador. Pendiente: despliegue en Arbitrum Sepolia y fase 2 (Liquid).

## Licencia

Sin licencia por ahora; todos los derechos reservados.

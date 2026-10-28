import { ZeroAddress, type Contract } from "ethers";

const ROL_CONTRATO = { emisor: "EMISOR", custodio: "CUSTODIO", agenteKyc: "AGENTE_KYC", supervisor: "SUPERVISOR", oraculo: "ORACULO", recuperador: "RECUPERADOR" } as const;

/** Tras el traspaso: admin final, cada rol solo en su dirección, el desplegador sin roles y sin traspaso pendiente. */
export async function verificarRoles(tepuy: Contract, desplegador: string, direcciones: { admin: string } & Record<keyof typeof ROL_CONTRATO, string>): Promise<void> {
  const { admin } = direcciones;
  if ((await tepuy.defaultAdmin()) !== admin) throw new Error("defaultAdmin inesperado");
  if ((await tepuy.pendingDefaultAdmin())[0] !== ZeroAddress) throw new Error("Queda un traspaso de admin pendiente");
  const adminRole = await tepuy.DEFAULT_ADMIN_ROLE();
  const todos: [string, string, string][] = [[adminRole, admin, "admin"]];
  for (const [clave, nombre] of Object.entries(ROL_CONTRATO)) todos.push([await tepuy[nombre](), direcciones[clave as keyof typeof ROL_CONTRATO], clave]);
  for (const cuenta of new Set([desplegador, ...todos.map(([, a]) => a)])) {
    for (const [rol, destino, clave] of todos) {
      if ((await tepuy.hasRole(rol, cuenta)) !== (cuenta === destino)) throw new Error(`Roles inesperados en ${cuenta} (${clave})`);
    }
  }
}

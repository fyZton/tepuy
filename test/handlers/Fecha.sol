// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Referencia ingenua e independiente (bucles por año y mes) para contrastar la conversión del contrato.
library Fecha {
    function _bisiesto(uint256 y) private pure returns (bool) {
        return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    }

    function de(uint256 ts) internal pure returns (uint32) {
        uint256 d = ts / 1 days;
        uint256 y = 1970;
        while (d >= (_bisiesto(y) ? 366 : 365)) {
            d -= _bisiesto(y) ? 366 : 365;
            y++;
        }
        uint8[12] memory dm = [31, _bisiesto(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        uint256 m;
        while (d >= dm[m]) {
            d -= dm[m];
            m++;
        }
        return uint32(y * 10000 + (m + 1) * 100 + d + 1);
    }
}

### 9. Consumidor que no coincide, por cada 100 transacciones

El nivel normal cambia mucho entre clusters, por eso auto-adaptativo y no un umbral fijo. Nueva.

Plantilla del evento. Título:
```
Nexus: consumidor que no coincide en {dims:cluster}
```
Descripción:
```
Subió por encima de lo normal (umbral auto-adaptativo) el WARN del mngr "Consumidor no coincide con el cuerpo
del mensaje" por cada 100 transacciones en {dims:cluster}, en 3 de las últimas 5 ventanas de 5 minutos.
Suele venir de un consumidor puntual.
Revisar en el tablero Nexus V2: "CONSUMIDOR QUE NO COINCIDE (por 100 tx)". Las líneas están en logs con
nexus.kind == "consumer_mismatch" (bucket logs_integracion, rango corto).
```

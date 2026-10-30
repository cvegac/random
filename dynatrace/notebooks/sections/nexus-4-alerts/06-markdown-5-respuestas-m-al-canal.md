### 5. % respuestas M al canal

La C no cuenta como M hasta que negocio defina qué es. Estático, ABOVE, umbral 40 % (a calibrar; después, línea base estacional).

Plantilla del evento. Título:
```
Nexus: % respuestas M al canal sobre 40 % en {dims:cluster}
```
Descripción:
```
Más del 40 % de las respuestas SOAP al canal en {dims:cluster} salieron con caracterAceptacion M en 3 de los
últimos 5 minutos. Los minutos con 10 respuestas o menos no cuentan.
M mezcla rechazos de negocio y errores técnicos, y el umbral todavía está a calibrar: ver primero si al mismo
tiempo hay alertas de error de los adaptadores; si no las hay, lo más probable es un cambio de negocio.
Revisar en el tablero Nexus V2: "% RESPUESTAS M POR CLUSTER" y "OPERACIONES CON MÁS RESPUESTAS M" (operación y código de mensaje).
```

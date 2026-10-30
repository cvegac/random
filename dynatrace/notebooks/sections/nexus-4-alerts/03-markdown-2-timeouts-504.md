### 2. Timeouts 504

Estático, ABOVE, umbral 2 por minuto.

Plantilla del evento. Título:
```
Nexus: timeouts 504 en {dims:cluster}
```
Descripción:
```
Más de 2 timeouts 504 por minuto en los adaptadores de {dims:cluster} en 3 de los últimos 5 minutos: el backend
no contestó dentro del timeout del adaptador.
Revisar en el tablero Nexus V2: "TIMEOUTS 504 POR SERVICIO Y CANAL" para ver a quién afecta y "TIMEOUTS 504 Y RESPUESTAS TARDÍAS
DE STRATUS": con respuestas tardías, Stratus contestó pero lento; sin ellas, Stratus no contestó.
```

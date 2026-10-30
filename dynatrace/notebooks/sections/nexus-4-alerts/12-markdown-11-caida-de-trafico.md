### 11. Caída de tráfico

Línea base estacional, BELOW, con alert on missing data encendido. Nueva.

Plantilla del evento. Título:
```
Nexus: caída de tráfico en {dims:cluster}
```
Descripción:
```
Las respuestas de los adaptadores de {dims:cluster} bajaron por debajo de lo normal para esta hora y día
(línea base estacional) en 3 de las últimas 5 ventanas de 5 minutos, o dejaron de llegar datos.
Puede ser que no llega tráfico del canal, que el adaptador está caído o que los logs dejaron de llegar a Dynatrace.
Revisar en el tablero Nexus V2: "RESPUESTAS ADAPTADOR EN EL TIEMPO" y "LOG GROUPS ENRUTADOS Y PROCESADOS" (salud del pipeline):
si el pipeline tampoco recibe líneas del cluster, la falla es de la ingesta y no del servicio.
Tablero con la alerta (Nexus V2, sección 3. Alertas en el rango, "11. CAÍDA DE TRÁFICO"):
<url-nexus-v2>
```

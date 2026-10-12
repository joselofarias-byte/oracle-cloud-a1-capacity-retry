# Oracle A1 automático — JolufaSoft

Adaptación del proyecto de filipbob para usarlo desde Termux con Debian.

## Instalar y usar

En Termux, dentro de la carpeta del repositorio:

```bash
bash termux.sh instalar
bash termux.sh configurar
bash termux.sh simular
bash termux.sh consultar
bash termux.sh iniciar
```

El asistente consulta la región principal, los dominios de disponibilidad y las
subredes públicas del compartimento raíz. No crea redes ni instancias. Necesita
un perfil OCI y una clave pública SSH existentes. Dentro de Debian, los archivos
del HOME de Termux están disponibles en `/termux-home`; por ejemplo,
`/termux-home/.oci/config`. El `key_file` del perfil debe señalar una ruta visible
dentro de Debian, como `/termux-home/.oci/oci_api_key.pem`.

La simulación verifica la estructura local sin llamar a Oracle. Consultar emite
informes de capacidad; iniciar sí solicita la creación cuando hay capacidad.

## Comportamiento

- Intenta 2 OCPU / 12 GB y luego 1 OCPU / 6 GB, según el uso disponible.
- Finaliza al crear una instancia, incluso si es de 1/6.
- Comprueba el uso A1 en el compartimento raíz antes de cada ciclo. Esta versión
  está diseñada para una cuenta cuyo cómputo A1 está en ese compartimento; el
  consumo en compartimentos hijos no se incluye.
- Usa un bloqueo atómico por cuenta configurada para impedir procesos paralelos.
- Guarda `.env.estado` **antes** de solicitar el lanzamiento. Si la respuesta es
  incierta, se detiene y no lanza otra instancia. Revisá la consola antes de
  retirar ese archivo. Si ya consiguió la instancia, conservá el archivo.
- Se detiene ante errores de autenticación, configuración y `LimitExceeded`.
- Los errores 429 aumentan la espera hasta 900 segundos.
- El asistente deja los registros visibles en pantalla. Se pueden guardar por
  día con `LOG_TO_FILE=1` en `.env`.

Termux mantiene un wake lock mientras el proceso está activo; Android puede
cerrarlo igualmente si restringe su batería. Debian usa el reloj del dispositivo;
el asistente desactiva la comprobación externa con sntp. OCI seguirá rechazando
firmas si el reloj es incorrecto.

Las credenciales, `.env`, estado y registros quedan excluidos de Git. El auxiliar
original `bootstrap_oci_network.sh` sigue disponible, pero no se ejecuta desde
este flujo: puede modificar las rutas y reglas de una red existente.

Validación realizada con OCI simulado; el funcionamiento real en Android y el
aprovisionamiento en Oracle necesitan ejecución desde tu dispositivo.

## Ejecución en GitHub Actions (sin mantener Termux abierto)

Detené el lanzador local con Ctrl+C. Actualizá el repositorio y activá:

```bash
git pull
bash activar-actions.sh
```

El activador usa `gh` autenticado y los archivos existentes en el celular. Carga
`OCI_CONFIG`, `OCI_PRIVATE_KEY` y `SSH_PUBLIC_KEY` como Secrets directamente,
sin imprimirlos. Guarda subred y nombre como variables, activa el workflow y
solicita una primera ejecución. La clave privada del SDK usa una carpeta
temporal de cada runner; no se guarda en código, artefactos ni rama de estado.
El activador presupone la ruta de clave API `~/.oci/oci_api_key.pem` usada en este
flujo de instalación. No modifica las claves de Oracle.

Cada corrida consulta una vez los tamaños 2/12 y 1/6 en los dominios de la
región principal. Cuenta consumo A1 en la raíz y los compartimentos activos
accesibles. Si una consulta falla, no solicita creación. Los compartimentos
que la identidad API no puede ver tampoco se pueden contabilizar: usá un
perfil que vea todo el cómputo de la cuenta.

El cron corre en los minutos 7, 22, 37 y 52 de cada hora UTC. GitHub puede
retrasar u omitir ejecuciones bajo carga: no garantiza intervalos exactos.
Cada trabajo dura como máximo diez minutos. Solo se admite main y hay una
sola corrida activa del workflow. No mantengas el lanzador local activo en
paralelo: su bloqueo es independiente del bloqueo de Actions.

El estado se guarda en `estado-a1.json` de la rama `a1-state`. Antes de cualquier
lanzamiento se confirma el guardado del estado `pending`; si falla, no lanza.
Cuando hay éxito queda `created`, y futuras corridas omiten instalación y OCI.
Errores de resultado incierto conservan `pending` o `uncertain` y requieren
revisión manual. No se reintenta ciegamente; se usa un token de idempotencia
y se desactivan los reintentos internos del SDK. Errores definitivos quedan
`fatal` y pausan futuros intentos. La rama contiene solo estado, tamaño,
fecha y token de petición; nunca credenciales ni OCIDs de recursos.

No borres ni edites esa rama para volver a intentar sin revisar la consola
Oracle primero. Un cambio de cuenta también requiere revisar el estado.
Después de crear una instancia, los eventos programados pueden seguir
abriendo trabajos cortos que solo leen el estado; se pueden desactivar:

```bash
gh variable set A1_ENABLED --repo joselofarias-byte/oracle-cloud-a1-capacity-retry --body false
```

Resultados: pestaña Actions → Oracle A1 programado → resumen de la corrida.
Los fallos generan el mecanismo habitual de notificaciones de GitHub según
las preferencias de la cuenta; no se configura Telegram ni email adicional.
En repositorios públicos GitHub puede desactivar cron tras 60 días sin
actividad. Podés reactivarlo desde Actions cuando corresponda. La cuota y
facturación de Actions dependen del plan y la visibilidad del repositorio.

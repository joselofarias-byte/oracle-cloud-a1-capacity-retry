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

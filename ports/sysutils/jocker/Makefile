# $FreeBSD$

PORTNAME=		jocker
PORTVERSION=	0.0.1
DISTVERSIONPREFIX=	v
CATEGORIES=		sysutils

MAINTAINER=		lasse@philomath.dk
COMMENT=		Docker-inspired tool for container management in FreeBSD

LICENSE=		BSD2CLAUSE

USES=			ssl

BUILD_DEPENDS=	elixir:lang/elixir rebar3:devel/rebar3 \
				${LOCALBASE}/lib/elixir/lib/hex/lib/hex.ex:devel/elixir-hex

RUN_DEPENDS=	erlc:lang/erlang

USE_RC_SUBR=	jockerd

USE_GITHUB=		yes

GH_TUPLE=		lgandersen:jocker_dist:b5e676f:DEFAULT

MIX_TARGET=		release
ELIXIR_APP_NAME?=	${PORTNAME}
MIX_ENV?=
ELIXIR_LOCALE?=		en_US.UTF-8
MIX_ENV_NAME?=		prod
MIX_CMD?=		${LOCALBASE}/bin/mix
MIX_COMPILE?=		${SETENV} ${MIX_ENV} LANG=${ELIXIR_LOCALE} LC_ALL=${ELIXIR_LOCALE} MIX_ENV=${MIX_ENV_NAME} ${MIX_CMD} ${MIX_TARGET}

ERTS_VSN=		erts-10.3.5.14
CRYPTO_VSN=		crypto-4.4.2.2

PLIST_SUB=	ERTS_VSN=${ERTS_VSN} CRYPTO_VSN=${CRYPTO_VSN}

RELEASE_PATH=	${WRKSRC}/_build/prod/rel/jockerd
RELEASE_BINARIES=	escript dialyzer erlexec beam.smp heart dyn_erl to_erl \
					erlc epmd run_erl typer inet_gethost erl_child_setup ct_run

do-build:
	@cd ${WRKSRC} && ${SETENV} MIX_HOME=${LOCALBASE}/bin ${MIX_COMPILE}
	@cd ${WRKSRC} && ${SETENV} MIX_HOME=${LOCALBASE}/bin ${MIX_CMD} escript.build

do-install:
	${INSTALL_DATA} ${WRKSRC}/example/jocker_config.yaml ${STAGEDIR}${PREFIX}/etc/
	${INSTALL_SCRIPT} ${WRKSRC}/jocker ${STAGEDIR}${PREFIX}/bin/
	${MKDIR} ${STAGEDIR}${PREFIX}/lib/jockerd/bin
	${INSTALL_SCRIPT} ${WRKSRC}/_build/prod/rel/jockerd/bin/jockerd ${STAGEDIR}${PREFIX}/lib/jockerd/bin/
	cd ${RELEASE_PATH}/lib && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/jockerd/lib
	cd ${RELEASE_PATH}/${ERTS_VSN}/bin && ${COPYTREE_BIN} . ${STAGEDIR}${PREFIX}/lib/jockerd/${ERTS_VSN}/bin
	cd ${RELEASE_PATH}/${ERTS_VSN}/lib && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/jockerd/${ERTS_VSN}/lib
	cd ${RELEASE_PATH}/releases && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/jockerd/releases
	${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/elixir ${STAGEDIR}${PREFIX}/lib/jockerd/releases/0.0.1/
	${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/iex ${STAGEDIR}${PREFIX}/lib/jockerd/releases/0.0.1/
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/jockerd/lib/${CRYPTO_VSN}/priv/lib/*.so
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/jockerd/lib/esqlite-0.4.1/priv/esqlite3_nif.so
.for bin in ${RELEASE_BINARIES}
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/jockerd/${ERTS_VSN}/bin/${bin}
.endfor

.include <bsd.port.mk>

# $FreeBSD$

PORTNAME=		jocker
PORTVERSION=	0.0.1
DISTVERSIONPREFIX=	v
CATEGORIES=		sysutils

MAINTAINER=     lasse@etableret.dk
COMMENT= 	    Docker-inspired tool for container management in FreeBSD

LICENSE=		BSD2CLAUSE

RUN_DEPENDS=	elixir:lang/elixir
BUILD_DEPENDS=  rebar3:devel/rebar3

USES=           elixir ssl

USE_GITHUB=     yes

GH_TUPLE=       lgandersen:jocker_dist:8a9ef03:DEFAULT

MIX_TARGET= 	release

ERTS=		 	erts-10.3.5.14
RELEASE_PATH=	${WRKSRC}/_build/prod/rel/jockerd
RELEASE_BINARIES= escript dialyzer erlexec beam.smp heart dyn_erl to_erl \
				  erlc epmd run_erl typer inet_gethost erl_child_setup ct_run

do-build:
	@cd ${WRKSRC} && ${SETENV} MIX_HOME=/usr/local/bin ${MIX_COMPILE}
	@cd ${WRKSRC} && ${SETENV} MIX_HOME=/usr/local/bin ${MIX_CMD} escript.build

do-install:
	${INSTALL_SCRIPT} ${WRKSRC}/jocker ${STAGEDIR}${PREFIX}/bin/
	${MKDIR} ${STAGEDIR}${PREFIX}/lib/jockerd/bin
	${INSTALL_SCRIPT} ${WRKSRC}/_build/prod/rel/jockerd/bin/jockerd ${STAGEDIR}${PREFIX}/lib/jockerd/bin/
	cd ${RELEASE_PATH}/lib && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/jockerd/lib
	cd ${RELEASE_PATH}/${ERTS}/bin && ${COPYTREE_BIN} . ${STAGEDIR}${PREFIX}/lib/jockerd/${ERTS}/bin
	cd ${RELEASE_PATH}/${ERTS}/lib && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/jockerd/${ERTS}/lib
	cd ${RELEASE_PATH}/releases && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/lib/jockerd/releases
	${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/elixir ${STAGEDIR}${PREFIX}/lib/jockerd/releases/0.0.1/
	${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/iex ${STAGEDIR}${PREFIX}/lib/jockerd/releases/0.0.1/
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/jockerd/lib/crypto-4.4.2.2/priv/lib/*.so
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/jockerd/lib/esqlite-0.4.1/priv/esqlite3_nif.so
.for bin in ${RELEASE_BINARIES}
	@${STRIP_CMD} ${STAGEDIR}${PREFIX}/lib/jockerd/${ERTS}/bin/${bin}
.endfor

.include <bsd.port.mk>

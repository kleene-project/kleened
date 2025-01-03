PORTNAME=		kleene-daemon
DISTVERSIONPREFIX=		v
DISTVERSION=		0.1.0rc2
CATEGORIES=		sysutils

MAINTAINER=		lasse@philomath.dk
COMMENT=		Kleene backend daemon for managing containers on FreeBSD
WWW=			https://kleene.dev

LICENSE=		BSD2CLAUSE

BUILD_DEPENDS=		${LOCALBASE}/lib/elixir/lib/hex/ebin:devel/elixir-hex \
			mix:lang/elixir \
			rebar3:devel/rebar3

USES=			gmake ssl
USE_GITHUB=		yes

GH_TUPLE=		kleene-project:kleened:6a67380:DEFAULT
USE_RC_SUBR=		kleened

SUB_FILES=		pkg-message

ETCDIR=			${PREFIX}/etc/kleened

MIX_TARGET=		release
ELIXIR_LOCALE=		en_US.UTF-8
ELIXIR_APP_NAME=	${PORTNAME}
MIX_ENV=		MIX_REBAR3=${LOCALBASE}/bin/rebar3 \
			LANG=${ELIXIR_LOCALE} LC_ALL=${ELIXIR_LOCALE} \
			MIX_PATH=${LOCALBASE}/lib/elixir/lib/hex/ebin \
			MIX_HOME=mix
MIX_ENV_NAME=		prod
MIX_COMPILE=		${SETENV} ${MIX_ENV} MIX_ENV=${MIX_ENV_NAME} mix \
			${MIX_TARGET}

RELEASE_PATH=		${WRKSRC}/_build/prod/rel/kleened
RELEASE_BINARIES=	escript dialyzer erlexec beam.smp heart dyn_erl to_erl \
			erlc epmd run_erl typer inet_gethost erl_child_setup \
			ct_run erl_call yielding_c_fun

.include <bsd.port.pre.mk>

do-build:
	@cd ${WRKSRC} && ${MIX_COMPILE}

do-install:
	${MKDIR} ${STAGEDIR}${PREFIX}/etc/kleened
	${INSTALL_DATA} ${WRKSRC}/example/kleened_config.yaml \
		${STAGEDIR}${PREFIX}/etc/kleened/config.yaml.sample
	${INSTALL_DATA} ${WRKSRC}/example/pf.conf.kleene \
		${STAGEDIR}${PREFIX}/etc/kleened/pf.conf.kleene.sample
	${MKDIR} ${STAGEDIR}${PREFIX}/libexec/kleened/bin
	${INSTALL_PROGRAM} ${WRKSRC}/priv/bin/kleened_pty \
		${STAGEDIR}${PREFIX}/libexec/kleened/bin/kleened_pty
	${INSTALL_SCRIPT} ${WRKSRC}/_build/prod/rel/kleened/bin/kleened \
		${STAGEDIR}${PREFIX}/libexec/kleened/bin/
	cd ${RELEASE_PATH}/lib && \
		${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/libexec/kleened/lib
	cd ${RELEASE_PATH} && \
		${COPYTREE_SHARE} ./erts-* ${STAGEDIR}${PREFIX}/libexec/kleened/ && \
		${CHMOD} +x ${STAGEDIR}${PREFIX}/libexec/kleened/erts-*/bin/*
	cd ${RELEASE_PATH}/releases && \
		${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/libexec/kleened/releases
	cd ${RELEASE_PATH}/releases && \
		${INSTALL_DATA} ${WRKSRC}/_build/prod/rel/kleened/releases/start_erl.data ${STAGEDIR}${PREFIX}/libexec/kleened/releases/
	${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/elixir \
		${STAGEDIR}${PREFIX}/libexec/kleened/releases/0.0.1/
	${INSTALL_SCRIPT} ${RELEASE_PATH}/releases/0.0.1/iex \
		${STAGEDIR}${PREFIX}/libexec/kleened/releases/0.0.1/
	${STRIP_CMD} ${STAGEDIR}${PREFIX}/libexec/kleened/lib/asn1-*/priv/lib/asn1rt_nif.so
	${STRIP_CMD} ${STAGEDIR}${PREFIX}/libexec/kleened/lib/crypto-*/priv/lib/*.so
	${STRIP_CMD} ${STAGEDIR}${PREFIX}/libexec/kleened/lib/exqlite-0.20.0/priv/sqlite3_nif.so
.for bin in ${RELEASE_BINARIES}
	${STRIP_CMD} ${STAGEDIR}${PREFIX}/libexec/kleened/erts-*/bin/${bin}
.endfor

post-install:
	@cd ${STAGEDIR}${PREFIX} && \
		${FIND} libexec/kleened/erts-* -type f -o -type l | ${SORT} >> ${TMPPLIST}
	@cd ${STAGEDIR}${PREFIX} && \
		${FIND} libexec/kleened/lib/* -type f -o -type l | ${SORT} >> ${TMPPLIST}

.include <bsd.port.post.mk>

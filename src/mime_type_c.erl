%%%----------------------------------------------------------------------
%%% File    : mime_type_c.erl
%%% Author  : Claes Wikstrom <klacke@hyber.org>
%%% Purpose :
%%% Created : 10 Jul 2002 by Claes Wikstrom <klacke@hyber.org>
%%%----------------------------------------------------------------------

-module(mime_type_c).
-author('klacke@hyber.org').

-export([generate/0, generate/3]).

-include("../include/yaws.hrl").


-define(MIME_TYPES_FILE, filename:join(yaws:get_priv_dir(), "mime.types")).
-define(DEFAULT_MIME_TYPE, "text/plain").

%% This function is used during Yaws' compilation. To rebuild/reload mime_types
%% module, generate/3 _MUST_ be used.
generate() ->
    %% By default, mime_types.erl is generated in the same directory than
    %% mime_type_c.erl. The priv directory is supposed to be relative to this
    %% source directory.
    SrcDir = filename:dirname(
               proplists:get_value(source, ?MODULE:module_info(compile))
              ),
    EbinDir = filename:dirname(code:which(?MODULE)),
    Charset = read_charset_file(filename:join(EbinDir, "../priv/charset.def")),
    GInfo   = #mime_types_info{
      mime_types_file = filename:join(SrcDir, "../priv/mime.types"),
      default_charset = Charset
     },
    ModFile = filename:join(SrcDir,  "mime_types.erl"),

    case generate(ModFile, GInfo, []) of
        ok ->
            erlang:halt(0);
        {error, Reason} ->
            error_logger:format("Cannot write module ~p: ~p\n",
                                [ModFile, file:format_error(Reason)]),
            erlang:halt(1)
    end.


%% GInfo      ::= #mime_types_info{}
%% SInfoMap   ::= [{{ServerName, Port}, #mime_types_info{}}]
%% ServerName ::= string() | atom()
generate(ModFile, GInfo, SInfoMap) ->
    case file:open(ModFile, [write]) of
        {ok, Fd} ->
            TypesData = [create_mime_types_data(Name, Info) ||
                            {Name, Info} <- [{global, GInfo}|SInfoMap] ],

            %% Generate module Header
            %%
            %% We must make the difference between generation during Yaws
            %% compilation and generation during Yaws startup.
            %% below, ignore dialyzer warning:
            %% "The pattern 'false' can never match the type 'true'"
            Inc = case yaws_generated:is_local_install() of
                      true ->
                          Info   = ?MODULE:module_info(compile),
                          SrcDir = filename:dirname(
                                     proplists:get_value(source, Info)
                                    ),
                          F = filename:join([SrcDir, "../include/yaws.hrl"]),
                          "-include(\""++F++"\").";
                      _ ->
                          "-include_lib(\"yaws/include/yaws.hrl\")."
                  end,
            io:format(Fd,
                      "-module(mime_types).~n~n"
                      "-export([default_type/0, default_type/1]).~n"
                      "-export([t/1, revt/1]).~n"
                      "-export([t/2, revt/2]).~n~n"
                      "~s~n~n", [Inc]),


            %% Generate default_type/0, t/1 and revt/1
            io:format(Fd,
                      "default_type() -> default_type(global).~n"
                      "t(Ext) -> t(global, Ext).~n"
                      "revt(Ext) -> revt(global, Ext).~n~n", []),

            %% Generate default_type/1
            io:format(Fd, "default_type(#sconf{servername=SN, port=P}) -> "
                      "default_type({SN,P});~n", []),
            lists:foreach(fun({Name, _, DefaultType, DefaultCharset}) ->
                                  generate_default_type(Fd, Name, DefaultType,
                                                        DefaultCharset)
                          end, TypesData),
            io:format(Fd, "default_type(_) -> default_type(global).~n~n", []),

            %% Generate t/2 function
            io:format(Fd, "t(#sconf{servername=SN, port=P}, Ext) -> "
                      "t({SN,P}, Ext);~n", []),
            lists:foreach(fun({Name, MimeTypes, DefaultType, DefaultCharset}) ->
                                  generate_t(Fd, Name, MimeTypes,
                                             DefaultType, DefaultCharset)
                          end, TypesData),
            io:format(Fd, "t(_, Ext) -> t(global, Ext).~n~n", []),

            %% Generate revt/2 function
            io:format(Fd,
                      "revt(#sconf{servername=SN, port=P}, Ext) -> "
                      "revt({SN,P}, Ext);~n",
                      []),
            lists:foreach(fun({Name, MimeTypes, DefaultType, DefaultCharset}) ->
                                  generate_revt(Fd, Name, MimeTypes,
                                                DefaultType, DefaultCharset)
                          end, TypesData),
            io:format(Fd, "revt(_, RExt) -> revt(global, RExt).~n", []),

            file:close(Fd),
            ok;

        {error, Reason} ->
            {error, Reason}
    end.


%% ----
create_mime_types_data(Name, Info) ->
    Charsets = Info#mime_types_info.charsets,
    DefaultC = case Info#mime_types_info.default_charset of
                   undefined -> "";
                   DCharset  -> "; charset=" ++ DCharset
               end,

    Map = case Info#mime_types_info.mime_types_file of
              undefined -> read_mime_types_file(?MIME_TYPES_FILE);
              File      -> read_mime_types_file(File)
          end,
    TypesData =
        lists:foldl(fun({Ext, MimeType}, Acc) ->
                            ExtType = get_ext_type(Ext),
                            Charset = case lists:keyfind(Ext, 1, Charsets) of
                                          {_,C} ->
                                              "; charset=" ++ C;
                                          false ->
                                              case MimeType of
                                                  "text/"++_ -> DefaultC;
                                                  _          -> ""
                                              end
                                      end,
                            lists:keystore(Ext, 1, Acc,
                                           {Ext, ExtType, MimeType, Charset})
                    end, [], Map ++ Info#mime_types_info.types),
    {Name, TypesData, Info#mime_types_info.default_type, DefaultC}.


%% ----
generate_default_type(Fd, Name, DefaultType, DefaultCharset) ->
    io:format(Fd, "default_type(~p) -> \"~s~s\";~n",
              [Name, DefaultType, DefaultCharset]).


%% ----
generate_t(Fd, Name, [], "text/"++_=DefaultType, DefaultCharset) ->
    io:format(Fd, "t(~p, _) -> {regular, \"~s~s\"};~n",
              [Name, DefaultType, DefaultCharset]);
generate_t(Fd, Name, [], DefaultType, _) ->
    io:format(Fd, "t(~p, _) -> {regular, \"~s\"};~n", [Name, DefaultType]);
generate_t(Fd, Name, [{Ext,ExtType,MimeType,Charset}|Rest],
           DefaultType, DefaultCharset) ->
    case string:to_upper(Ext) of
        Ext ->
            io:format(Fd, "t(~p, ~p) -> {~p, \"~s~s\"};~n",
                      [Name, Ext, ExtType, MimeType, Charset]);
        UExt ->
            io:format(Fd,
                      "t(~p, ~p) -> {~p, \"~s~s\"};~n"
                      "t(~p, ~p) -> {~p, \"~s~s\"};~n",
                      [Name, Ext, ExtType, MimeType, Charset,
                       Name, UExt, ExtType, MimeType, Charset])
    end,
    generate_t(Fd, Name, Rest, DefaultType, DefaultCharset).


%% ----
generate_revt(Fd, Name, [], "text/"++_=DefaultType, DefaultCharset) ->
    io:format(Fd,
              "revt(~p, RExt) -> {regular, lists:reverse(RExt), \"~s~s\"};~n",
              [Name, DefaultType, DefaultCharset]);
generate_revt(Fd, Name, [], DefaultType, _) ->
    io:format(Fd,
              "revt(~p, RExt) -> {regular, lists:reverse(RExt), \"~s\"};~n",
              [Name, DefaultType]);
generate_revt(Fd, Name, [{Ext,ExtType,MimeType,Charset}|Rest],
           DefaultType, DefaultCharset) ->
    RExt = lists:reverse(Ext),
    case string:to_upper(Ext) of
        Ext ->
            io:format(Fd,
                      "revt(~p, ~p) -> {~p, ~p, \"~s~s\"};~n",
                      [Name, RExt, ExtType, Ext, MimeType, Charset]);
        UExt ->
            RUExt = lists:reverse(UExt),
            io:format(Fd,
                      "revt(~p, ~p) -> {~p, ~p, \"~s~s\"};~n"
                      "revt(~p, ~p) -> {~p, ~p, \"~s~s\"};~n",
                      [Name, RExt, ExtType, Ext, MimeType, Charset,
                       Name, RUExt, ExtType, UExt, MimeType, Charset])
    end,
    generate_revt(Fd, Name, Rest, DefaultType, DefaultCharset).



%% ----
read_charset_file(File) ->
    case file:read_file(File) of
        {ok, B} ->
            case string:tokens(binary_to_list(B),"\r\n\s\t\0\f") of
                [] ->
                    undefined;
                [Charset] ->
                    string:strip(Charset, both, 10);
                _ ->
                    error_logger:format("Ignoring bad charset in ~p\n", [File]),
                    undefined
            end;
        {error, Reason} ->
            error_logger:format("Cannot read ~p: ~p\n",
                                [File, file:format_error(Reason)]),
            undefined
    end.


%% ----
read_mime_types_file(File) ->
    case file:open(File, [read]) of
        {ok, Io} ->
            %% Define mime-types for special extensions. It could be overridden
            Acc0 = [{E, "text/html"} || E <- get_special_exts()],
            read_mime_types_file(Io, 1, file:read_line(Io), Acc0);
        {error, Reason} ->
            error_logger:format("Cannot read ~p: ~p\n",
                                [File, file:format_error(Reason)]),
            []
    end.

read_mime_types_file(Io, _, eof, Acc) ->
    file:close(Io),
    lists:reverse(Acc);
read_mime_types_file(Io, Lno, {error, Reason}, Acc) ->
    file:close(Io),
    error_logger:format("read mime-types config failed at line ~p: ~p\n",
                        [Lno, file:format_error(Reason)]),
    lists:reverse(Acc);
read_mime_types_file(Io, Lno, {ok, [$#|_]}, Acc) ->
    read_mime_types_file(Io, Lno+1, file:read_line(Io), Acc);
read_mime_types_file(Io, Lno, {ok, [$\s|_]}, Acc) ->
    read_mime_types_file(Io, Lno+1, file:read_line(Io), Acc);
read_mime_types_file(Io, Lno, {ok, Line}, Acc0) ->
    case string:tokens(Line,"\r\n\s\t\0\f") of
        []  ->
            read_mime_types_file(Io, Lno+1, file:read_line(Io), Acc0);
        [_] ->
            read_mime_types_file(Io, Lno+1, file:read_line(Io), Acc0);
        [MimeType | Exts] ->
            Acc1 = lists:foldl(fun(Ext, Acc) ->
                                       lists:keystore(Ext, 1, Acc,
                                                      {Ext, MimeType})
                               end, Acc0, Exts),
            read_mime_types_file(Io, Lno+1, file:read_line(Io), Acc1)
    end.


%% ----
get_special_exts() -> ["yaws", "php", "cgi", "fcgi"].

get_ext_type("yaws") -> yaws;
get_ext_type("php")  -> php;
get_ext_type("cgi")  -> cgi;
get_ext_type("fcgi") -> fcgi;
get_ext_type(_)      -> regular.


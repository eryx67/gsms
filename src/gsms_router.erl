%%%---- BEGIN COPYRIGHT --------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2012, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ----------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @doc
%%%     Message router for SMS
%%% @end
%%% Created : 17 Apr 2013 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(gsms_router).

-behaviour(gen_server).

%% API
-export([start_link/1]).
-compile(export_all).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("lager/include/log.hrl").
-include("../include/gsms.hrl").

-define(SERVER, ?MODULE). 

-type filter() :: 
	[filter()] |
	{type,     dcs_type()} |
	{class,    dcs_class()} |
	{alphabet, dcs_alphabet()} |
	{pid,      gsms_pid()} |
	{src,      gsms_port()} |
	{dst,      gsms_port()} |
	{anumber,  gsms_addr()} |
	{bnumber,  gsms_addr()} |
	{smsc,     gsms_addr()} |
	{'not', filter()} |
	{'and', filter(), filter()} |
	{'or', filter(), filter()}.
	
-record(subscription,
	{
	  pid  :: pid(),       %% subscriber process
	  ref  :: reference(), %% reference / monitor
	  filter = [] :: filter()
	}).

-record(interface,
	{
	  pid     :: pid(),        %% interface pid
	  mon     :: reference(),  %% monitor reference
	  bnumber :: gsms_addr(),  %% modem msisdn
	  attributes = [] :: [{atom(),term()}]  %% general match keys
	}).

-record(state, 
	{
	  subs = [] :: [#subscription{}],
	  ifs  = [] :: [#interface{}]
	}).

%%%===================================================================
%%% API
%%%===================================================================


send(Opts, Body) ->
    gen_server:call(?SERVER, {send, Opts, Body}).

-spec subscribe(Filter::[filter()]) -> {ok,Ref::reference()} |
				       {error,Reason::term()}.

subscribe(Filter) ->
    gen_server:call(?SERVER, {subscribe, self(), Filter}).

-spec unsubscribe(Ref::reference()) -> ok.

unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe, Ref}).

join(BNumber,Attributes) ->
    gen_server:call(?SERVER, {join,self(),BNumber,Attributes}).

%%
%% Called from gsms_srv backend to enter incoming message
%%
input_from(BNumber, Sms) ->
    lager:debug("message input modem:~s, message = ~p\n",
		[BNumber, Sms]),
    ?SERVER ! {input_from, BNumber, Sms},
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(_Args) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({send,Opts,Body}, _From, State) ->
    %% forward to the correct interface handler
    %% FIXME: add code to match attributes!
    case proplists:get_value(bnumber, Opts) of
	undefined ->
	    case State#state.ifs of 
		[I|_] ->
		    Reply = gsms_srv:send(I#interface.pid, Opts, Body),
		    {reply, Reply, State};
		[] ->
		    {reply, {error,enoent}, State}
	    end;
	BNumber ->
	    case lists:keyfind(BNumber,#interface.bnumber,State#state.ifs) of
		false ->
		    {reply, {error,enoent}, State};
		I ->
		    Reply = gsms_srv:send(I#interface.pid, Opts, Body),
		    {reply, Reply, State}
	    end
    end;
handle_call({subscribe,Pid,Filter}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    Subs = [#subscription { pid = Pid,
			    ref = Ref,
			    filter = Filter } | State#state.subs],
    {reply, {ok,Ref}, State#state { subs = Subs} };
handle_call({unsubscribe,Ref}, _From, State) ->
    case lists:keytake(Ref, #subscription.ref, State#state.subs) of
	false -> 
	    {reply, ok, State};
	{value,_S,Subs} ->
	    erlang:demonitor(Ref, [flush]),
	    {reply, ok, State#state { subs = Subs} }
    end;
handle_call({join,Pid,BNumber,Attributes}, _From, State) ->
    case lists:keytake(BNumber, #interface.bnumber, State#state.ifs) of
	false ->
	    ?debug("gsms_router: process ~p, bnumber ~p joined.",
		   [Pid, BNumber]),
	    State1 = add_interface(Pid,BNumber,Attributes,State),
	    {reply, ok, State1};
	{value,I,IFs} ->
	    receive
		{'EXIT', OldPid, _Reason} when I#interface.pid =:= OldPid ->
		    ?debug("join: restart detected", []),
		    State1 = add_interface(Pid,BNumber,Attributes,
					   State#state { ifs=IFs} ),
		    {reply, ok, State1}
	    after 0 ->
		    {reply, {error,ealready}, State}
	    end
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN',Ref,process,Pid,_Reason}, State) ->
    case lists:keytake(Ref, #subscription.ref, State#state.subs) of
	false -> 
	    case lists:keytake(Pid, #interface.pid, State#state.ifs) of
		false ->
		    {noreply, State};
		{value,_If,Ifs} ->
		    ?debug("gsms_router: interface ~p died, reason ~p\n", 
			   [_If, _Reason]),
		    %% Restart done by gsms_if_sup
		    {noreply,State#state { ifs = Ifs }}
	    end;
	{value,_S,Subs} ->
	    {noreply, State#state { subs = Subs} }
    end;

handle_info({input_from, BNumber, Pdu}, State) ->
    lager:debug("input bnumber: ~p, pdu=~p\n", [BNumber,Pdu]),
    lists:foreach(
      fun(S) ->
	      lager:debug("match filter: ~p\n", [S#subscription.filter]),
	      case match(S#subscription.filter, BNumber, Pdu) of
		  true ->
		      lager:debug("match success send to ~p", 
				  [S#subscription.pid]),
		      S#subscription.pid ! {gsms, S#subscription.ref, Pdu};
		  false ->
		      lager:debug("match fail"),
		      ok
	      end
      end, State#state.subs),
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    case lists:keytake(Pid, #interface.pid, State#state.ifs) of
	{value,_If,Ifs} ->
	    %% One of our interfaces died, log and ignore
	    ?debug("gsms_router: interface ~p died, reason ~p\n", 
		   [_If, Reason]),
	    {noreply,State#state { ifs = Ifs }};
	false ->
	    %% Someone else died, log and terminate
	    ?debug("gsms_router: linked process ~p died, reason ~p, terminating\n", 
		   [Pid, Reason]),
	    {stop, Reason, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

add_interface(Pid,BNumber,Attributes,State) ->
    Mon = erlang:monitor(process, Pid),
    I = #interface { pid=Pid, mon=Mon,
		     bnumber=BNumber, attributes=Attributes },
    link(Pid),
    State#state { ifs = [I | State#state.ifs ] }.


match(As, BNum, Sms) when is_list(As) ->
    match_clause(As, BNum, Sms);
match({'not',Filter}, BNum, Sms) ->
    not match(Filter, BNum, Sms);
match({'and',A,B}, BNum, Sms) ->
    match(A,BNum,Sms) andalso match(B,BNum,Sms);
match({'or',A,B}, BNum, Sms) ->
    match(A,BNum,Sms) orelse match(B,BNum,Sms);
match({bnumber,Addr}, BNum, _Sms) -> 
    %% receiving modem
    match_addr(Addr, BNum);
match(Match, _BNum, Sms) ->
    match_sms(Match, Sms).

match_clause([A|As], BNum, Sms) ->
    case match(A, BNum, Sms) of
	true -> match_clause(As, BNum, Sms);
	false -> false
    end;
match_clause([], _BNum, _Sms) ->
    true.

match_sms({type,Type}, Sms) ->
    case Sms#gsms_deliver_pdu.dcs of
	[Type|_] ->  true;
	_ -> false
    end;
match_sms({alphabet,Alphabet}, Sms) ->
    case Sms#gsms_deliver_pdu.dcs of
	[_Type,_Compress,Alphabet|_] -> true;
	_ -> false
    end;
match_sms({class,Class}, Sms) ->
    case Sms#gsms_deliver_pdu.dcs of
	[_Type,_Compress,_Alphabet,Class|_] -> true;
	_ -> false
    end;
match_sms({pid,Pid}, Sms) ->
    Sms#gsms_deliver_pdu.pid =:= Pid;
match_sms({dst,Port}, Sms) ->
    case lists:keyfind(1, port, Sms#gsms_deliver_pdu.udh) of
	{port,Port,_} -> true;
	_ -> false
    end;
match_sms({src,Port}, Sms) ->
    case lists:keyfind(1, port, Sms#gsms_deliver_pdu.udh) of
	{port,_,Port} -> true;
	_ -> false
    end;
match_sms({anumber,Addr}, Sms) ->
    match_addr(Addr, Sms#gsms_deliver_pdu.addr);
match_sms({smsc,Addr}, Sms) ->
    match_addr(Addr, Sms#gsms_deliver_pdu.smsc).

%% Add some more smart matching here to select international / national
%% country suffix etc.
match_addr(Addr, Addr) -> true;
match_addr(Addr, #gsms_addr { addr = Addr }) when is_list(Addr) -> true;
match_addr(#gsms_addr { type=unknown, addr=Addr},
	   #gsms_addr { addr=Addr}) -> true;
match_addr(_, _) -> false.

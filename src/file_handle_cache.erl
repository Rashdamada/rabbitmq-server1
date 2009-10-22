%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(file_handle_cache).

-export([init/0, open/4, close/2, release/2, read/4, append/3, sync/2,
         position/3, truncate/2, last_sync_offset/2]).

-record(file,
        { reader_count,
          has_writer,
          path
        }).

-record(handle,
        { hdl,
          offset,
          trusted_offset,
          write_buffer_size,
          write_buffer_size_limit,
          write_buffer,
          at_eof,
          is_write,
          is_read,
          mode,
          options,
          global_key,
          last_used_at
        }).

init() -> empty_state.

open(Path, Mode, Options, State) ->
    case is_appender(Mode) of
        true -> {{error, append_not_supported}, State};
        false ->
            Path1 = filename:absname(Path),
            case get({Path1, fhc_path}) of
                {gref, GRef} ->
                    #file { reader_count = RCount, has_writer = HasWriter }
                        = File = get({GRef, fhc_file}),
                    Mode1 = lists:usort(Mode),
                    IsWriter = is_writer(Mode1),
                    case IsWriter andalso HasWriter of
                        true ->
                            {{error, writer_exists}, State};
                        false ->
                            RCount1 = case is_reader(Mode1) of
                                          true -> RCount + 1;
                                          false -> RCount
                                      end,
                            put({Path1, fhc_file},
                                File #file {
                                  reader_count = RCount1,
                                  has_writer = HasWriter orelse IsWriter }),
                            Ref = make_ref(),
                            case open1(Path1, Mode1, Options, Ref, GRef, State)
                                of
                                {{ok, _Handle}, State} -> {{ok, Ref}, State};
                                {Error, State} -> {Error, State}
                            end
                    end;
                undefined ->
                    GRef = make_ref(),
                    put({Path1, fhc_path}, {gref, GRef}),
                    put({GRef, fhc_file},
                        #file { reader_count = 0, has_writer = false,
                                path = Path1 }),
                    open(Path, Mode, Options, State)
            end
    end.

close(Ref, State) ->
    case erase({Ref, fhc_handle}) of
        undefined -> {ok, State};
        Handle ->
            case write_buffer(Handle) of
                {ok, #handle { hdl = Hdl, global_key = GRef,
                               is_read = IsReader, is_write = IsWriter }} ->
                    case Hdl of
                        closed -> ok;
                        _ -> ok = file:sync(Hdl),
                             ok = file:close(Hdl)
                    end,
                    #file { reader_count = RCount, has_writer = HasWriter,
                            path = Path } = File = get({GRef, fhc_file}),
                    RCount1 = case IsReader of
                                  true -> RCount - 1;
                                  false -> RCount
                              end, 
                    HasWriter1 = HasWriter andalso not IsWriter,
                    case RCount1 == 0 andalso not HasWriter1 of
                        true -> erase({GRef, fhc_file}),
                                erase({Path, fhc_path});
                        false -> put({GRef, fhc_file},
                                     File #file { reader_count = RCount1,
                                                  has_writer = HasWriter1 })
                    end,
                    {ok, State};
                {Error, Handle1} ->
                    put({Ref, fhc_handle}, Handle1),
                    {Error, State}
            end
    end.

release(_Ref, State) -> %% noop just for now
    {ok, State}.

read(Ref, NewOffset, Count, State) ->
    case get_or_reopen(Ref, State) of
        {{ok, #handle { is_read = false }}, State1} ->
            {{error, not_open_for_reading}, State1};
        {{ok, Handle}, State1} ->
            {Result, Handle1} =
                case write_buffer(Handle) of
                    {ok, Handle2} ->
                        case maybe_seek(NewOffset, Handle2) of
                            {ok, Handle3 = #handle { hdl = Hdl,
                                                     offset = Offset }} ->
                                case file:read(Hdl, Count) of
                                    {ok, _} = Obj ->
                                        {Obj, Handle3 #handle {
                                                offset = Offset + Count }};
                                    eof ->
                                        {eof, Handle3 #handle {
                                                at_eof = true }};
                                    {error, _} = Error ->
                                        {Error, Handle3}
                                end;
                            {Error, Handle3} -> {Error, Handle3}
                        end;
                    {Error, Handle2} -> {Error, Handle2}
                end,
            put({Ref, fhc_handle}, Handle1 #handle { last_used_at = now() }),
            {Result, State1};
        ErrorAndState -> ErrorAndState
    end.

append(Ref, Data, State) ->
    case get_or_reopen(Ref, State) of
        {{ok, #handle { is_write = false }}, State1} ->
            {{error, not_open_for_writing}, State1};
        {{ok, Handle}, State1} ->
            {Result, Handle1} =
                case maybe_seek(eof, Handle) of
                    {ok, Handle2 = #handle { at_eof = true }} ->
                        write_to_buffer(Data, Handle2);
                    {{error, _} = Error, Handle2} ->
                        {Error, Handle2}
                end,
            put({Ref, fhc_handle}, Handle1 #handle { last_used_at = now() }),
            {Result, State1};
        ErrorAndState -> ErrorAndState
    end.

last_sync_offset(Ref, State) ->
    case get_or_reopen(Ref, State) of
        {{ok, #handle { trusted_offset = TrustedOffset }}, State1} ->
            {{ok, TrustedOffset}, State1};
        ErrorAndState -> ErrorAndState
    end.

position(Ref, NewOffset, State) ->
    case get_or_reopen(Ref, State) of
        {{ok, Handle}, State1} ->
            {Result, Handle1} =
                case write_buffer(Handle) of
                    {ok, Handle2} -> maybe_seek(NewOffset, Handle2);
                    {Error, Handle2} -> {Error, Handle2}
                end,
            put({Ref, fhc_handle}, Handle1 #handle { last_used_at = now() }),
            {Result, State1};
        ErrorAndState -> ErrorAndState
    end.

sync(Ref, State) ->
    case get_or_reopen(Ref, State) of
        {{ok, Handle = #handle { write_buffer = [], hdl = Hdl,
                                 offset = Offset }}, State1} ->
            {Result, Handle1} =
                case file:sync(Hdl) of
                    ok -> {ok, Handle #handle { trusted_offset = Offset }};
                    Error -> {Error, Handle}
                end,
            put({Ref, fhc_handle}, Handle1 #handle { last_used_at = now() }),
            {Result, State1};
        {{ok, Handle = #handle { at_eof = true }}, State1} ->
            %% we can't have content in the buffer without being at eof
            {Result, Handle1} = write_buffer(Handle),
            put({Ref, fhc_handle}, Handle1 #handle { last_used_at = now() }),
            {Result, State1};
        ErrorAndState -> ErrorAndState
    end.

truncate(Ref, State) ->
    case get_or_reopen(Ref, State) of
        {{ok, #handle { is_write = false }}, State1} ->
            {{error, not_open_for_writing}, State1};
        {{ok, Handle}, State1} ->
            {Result, Handle1} =
                case write_buffer(Handle) of
                    {ok,
                     Handle2 = #handle { hdl = Hdl, offset = Offset,
                                         trusted_offset = TrustedOffset }} ->
                        case file:truncate(Hdl) of
                            ok ->
                                {ok,
                                 Handle2 #handle {
                                   at_eof = true,
                                   trusted_offset = lists:min([Offset,
                                                               TrustedOffset])
                                  }};
                            Error -> {Error, Handle2}
                        end;
                    {Error, Handle2} -> {Error, Handle2}
                end,
            put({Ref, fhc_handle}, Handle1 #handle { last_used_at = now () }),
            {Result, State1};
        ErrorAndState -> ErrorAndState
    end.

get_or_reopen(Ref, State) ->
    case get({Ref, fhc_handle}) of
        undefined -> {{error, not_open}, State};
        #handle { hdl = closed, mode = Mode, global_key = GRef,
                  options = Options } ->
            #file { path = Path } = get({GRef, fhc_file}),
            open1(Path, Mode, Options, Ref, GRef, State);
        Handle -> {{ok, Handle}, State}
    end.

open1(Path, Mode, Options, Ref, GRef, State) ->
    case file:open(Path, Mode) of
        {ok, Hdl} ->
            WriteBufferSize =
                case proplists:get_value(write_buffer, Options, unbuffered) of
                    unbuffered -> 0;
                    infinity -> infinity;
                    N when is_integer(N) -> N
                end,
            Handle =
                #handle { hdl = Hdl, offset = 0, trusted_offset = 0,
                          write_buffer_size = 0, options = Options,
                          write_buffer_size_limit = WriteBufferSize,
                          write_buffer = [], at_eof = false, mode = Mode,
                          is_write = is_writer(Mode), is_read = is_reader(Mode),
                          global_key = GRef, last_used_at = now() },
            put({Ref, fhc_handle}, Handle),
            {{ok, Handle}, State};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

maybe_seek(NewOffset, Handle = #handle { hdl = Hdl, at_eof = AtEoF,
                                         offset = Offset }) ->
    {AtEoF1, NeedsSeek} = needs_seek(AtEoF, Offset, NewOffset),
    Result = case NeedsSeek of
                 true -> file:position(Hdl, NewOffset);
                 false -> {ok, Offset}
             end,
    case Result of
        {ok, Offset1} ->
            {ok, Handle #handle { at_eof = AtEoF1, offset = Offset1 }};
        {error, _} = Error -> {Error, Handle}
    end.

write_to_buffer(Data, Handle = #handle { hdl = Hdl,
                                         write_buffer_size_limit = 0 }) ->
    {file:write(Hdl, Data), Handle};
write_to_buffer(Data, Handle =
                #handle { write_buffer = WriteBuffer,
                          write_buffer_size = Size,
                          write_buffer_size_limit = Limit }) ->
    Size1 = Size + size_of_write_data(Data),
    Handle1 = Handle #handle { write_buffer = [ Data | WriteBuffer ],
                               write_buffer_size = Size1 },
    case Limit /= infinity andalso Size1 > Limit of
        true -> write_buffer(Handle1);
        false -> {ok, Handle1}
    end.

write_buffer(Handle = #handle { write_buffer = [] }) ->
    {ok, Handle};
write_buffer(Handle = #handle { hdl = Hdl, offset = Offset,
                                write_buffer = WriteBuffer,
                                write_buffer_size = DataSize,
                                at_eof = true }) ->
    case file:write(Hdl, lists:reverse(WriteBuffer)) of
        ok ->
            Offset1 = Offset + DataSize,
            {ok, Handle #handle { offset = Offset1, write_buffer = [],
                                  write_buffer_size = 0 }};
        {error, _} = Error ->
            {Error, Handle}
    end.

size_of_write_data(Data) ->
    size_of_write_data(Data, 0).

size_of_write_data([], Acc) ->
    Acc;
size_of_write_data([A|B], Acc) ->
    size_of_write_data(B, size_of_write_data(A, Acc));
size_of_write_data(Bin, Acc) when is_binary(Bin) ->
    size(Bin) + Acc.

is_reader(Mode) -> lists:member(read, Mode).

is_writer(Mode) -> lists:member(write, Mode).

is_appender(Mode) -> lists:member(append, Mode).

needs_seek(AtEof, _CurOffset, DesiredOffset)
  when DesiredOffset == cur orelse DesiredOffset == {cur, 0} ->
    {AtEof, false};
needs_seek(true, _CurOffset, DesiredOffset)
  when DesiredOffset == eof orelse DesiredOffset == {eof, 0} ->
    {true, false};
needs_seek(false, _CurOffset, DesiredOffset)
  when DesiredOffset == eof orelse DesiredOffset == {eof, 0} ->
    {true, true};
needs_seek(AtEof, 0, DesiredOffset)
  when DesiredOffset == bof orelse DesiredOffset == {bof, 0} ->
    {AtEof, false};
needs_seek(AtEof, CurOffset, CurOffset) ->
    {AtEof, false};
needs_seek(true, CurOffset, {bof, DesiredOffset})
  when DesiredOffset >= CurOffset ->
    {true, true};
needs_seek(true, _CurOffset, {cur, DesiredOffset})
  when DesiredOffset > 0 ->
    {true, true};
needs_seek(true, CurOffset, DesiredOffset) %% same as {bof, DO}
  when is_integer(DesiredOffset) andalso DesiredOffset >= CurOffset ->
    {true, true};
%% because we can't really track size, we could well end up at EoF and not know
needs_seek(_AtEoF, _CurOffset, _DesiredOffset) ->
    {false, true}.

package service

import (
	"context"
	"fmt"
	"sort"

	"github.com/sirerun/MISTT/internal/ipc"
)

func commandPayload(m ipc.NativeMessage) string {
	return fmt.Sprintf("%s|%s|%d|%d|%t", m.Type, m.RequestID, m.CommandSequence, m.ExpectedStatusRevision, m.Muted)
}
func (s *Service) applyNativeCommand(m ipc.NativeMessage) error {
	payload := commandPayload(m)
	var cancelStart context.CancelFunc
	s.mu.Lock()
	if prior, ok := s.commands[m.CommandSequence]; ok {
		if prior.requestID == m.RequestID && prior.payload == payload {
			result := prior.result
			s.mu.Unlock()
			return s.output.SendControl(result)
		}
		result := s.resultLocked(m.RequestID, "stale_command", "command sequence was already used with another payload")
		s.mu.Unlock()
		return s.output.SendControl(result)
	}
	if seq, ok := s.requestCommands[m.RequestID]; ok && seq != m.CommandSequence {
		result := s.resultLocked(m.RequestID, "stale_command", "request ID was already used by another command")
		s.mu.Unlock()
		return s.output.SendControl(result)
	}
	if m.CommandSequence <= s.commandHigh {
		result := s.resultLocked(m.RequestID, "stale_command", "command sequence is stale or evicted")
		s.mu.Unlock()
		return s.output.SendControl(result)
	}
	s.commandHigh = m.CommandSequence
	var errorCode, errorDetail string
	if m.ExpectedStatusRevision != s.revision {
		errorCode = "status_conflict"
		errorDetail = "expected status revision is stale; relay state was not changed"
	} else {
		switch m.Type {
		case "native_set_muted":
			if !m.Muted && s.updateReserved {
				errorCode = "status_conflict"
				errorDetail = "an update reservation blocks unmute"
			} else if !m.Muted && !s.closureConfirmed {
				errorCode = "status_conflict"
				errorDetail = "paired closure is not confirmed"
			} else if s.muted != m.Muted {
				s.muted = m.Muted
				if m.Muted {
					s.reason = "user"
					cancelStart = s.startCancel
				} else {
					s.reason = "armed"
				}
				s.publishLocked()
				s.signalLocked()
			}
		case "native_prepare_update":
			if !s.updateReadyLocked() || s.updateReserved {
				errorCode = "status_conflict"
				errorDetail = "paired capture is not safely idle for update"
			} else {
				s.updateReserved = true
				s.publishLocked()
				s.signalLocked()
			}
		case "native_cancel_update":
			if !s.updateReserved {
				errorCode = "status_conflict"
				errorDetail = "there is no update reservation to cancel"
			} else {
				s.updateReserved = false
				s.publishLocked()
				s.signalLocked()
			}
		default:
			s.mu.Unlock()
			return fmt.Errorf("unsupported native command type %q", m.Type)
		}
	}
	result := s.resultLocked(m.RequestID, errorCode, errorDetail)
	s.commands[m.CommandSequence] = commandRecord{requestID: m.RequestID, payload: payload, result: result}
	s.requestCommands[m.RequestID] = m.CommandSequence
	s.pruneCommandsLocked()
	s.mu.Unlock()
	if cancelStart != nil {
		cancelStart()
	}
	return s.output.SendControl(result)
}
func (s *Service) resultLocked(requestID, code, detail string) ipc.NativeMessage {
	result := ipc.NativeMessage{Type: "control_result", RequestID: requestID, Status: &ipc.NativeStatus{Muted: s.muted, Capturing: s.capturing, ConnectedClients: uint32(len(s.clients)), Reason: s.reason, Revision: s.revision, UpdateReady: s.updateReadyLocked(), UpdateReserved: s.updateReserved}}
	if code != "" {
		result.Error = &ipc.NativeError{Code: code, Detail: detail}
	}
	return result
}
func (s *Service) pruneCommandsLocked() {
	if len(s.commands) <= 128 {
		return
	}
	keys := make([]uint64, 0, len(s.commands))
	for k := range s.commands {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	for _, k := range keys[:len(keys)-128] {
		delete(s.requestCommands, s.commands[k].requestID)
		delete(s.commands, k)
	}
}
